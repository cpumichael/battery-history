import SwiftUI
import Charts
import BatteryHistoryCore

private enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1H", day = "24H", week = "7D", month = "30D", all = "All", custom = "Custom"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .hour: return 3600
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .all, .custom: return nil
        }
    }
}

private struct PlotPoint: Identifiable {
    let reading: BatteryReading
    let segment: Int
    let isolated: Bool
    var id: UUID { reading.id }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var range = HistoryRange.day
    @State private var customStart = Date().addingTimeInterval(-86400)
    @State private var customEnd = Date()
    @State private var points: [PlotPoint] = []
    @State private var count = 0
    @State private var domain = Date().addingTimeInterval(-86400)...Date()
    @State private var loading = false
    @State private var queryError: String?
    @State private var hovered: BatteryReading?
    @State private var generation = UUID()

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Battery History").font(.largeTitle.weight(.semibold))
                    Text(model.preview ? "Preview · synthetic battery history" : "A longer view of your Mac’s battery.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.storageError == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.preview ? "Preview" : (!model.ready ? "Starting…" : (model.storageError != nil ? "Storage error" :
                        (model.current == nil ? "No battery" : "Recording"))))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
            HStack(spacing: 16) {
                metric("BATTERY", value: model.current.map { "\(Int($0.percent.rounded()))%" } ?? "—",
                       detail: model.current?.state.label ?? "No internal battery found", icon: "battery.75percent")
                metric(model.current?.state == .charging ? "CHARGING RATE" : "DRAIN RATE",
                       value: model.rate.map { String(format: "%.1f", abs($0)) + " pp/h" } ?? "—",
                       detail: "Recent 30-minute trend", icon: "waveform.path")
                metric(model.current?.state == .charging ? "UNTIL FULL" : "TIME REMAINING",
                       value: model.current?.estimatedMinutes.map(durationText) ?? "—",
                       detail: "macOS estimate", icon: "clock")
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Charge over time").font(.headline)
                    Spacer()
                    Picker("Date range", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 350)
                }
                if range == .custom {
                    HStack {
                        DatePicker("From", selection: $customStart)
                        DatePicker("To", selection: $customEnd)
                    }.datePickerStyle(.field)
                }
                if let error = model.storageError ?? queryError {
                    ContentUnavailableView {
                        Label("History unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if loading && points.isEmpty {
                    ProgressView("Loading history…").frame(maxWidth: .infinity, minHeight: 260)
                } else if points.isEmpty {
                    ContentUnavailableView {
                        Label("No readings in this range", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(model.current == nil ? "An internal Mac battery is needed to record history." :
                            "History begins now. Leave the app running to build your timeline.")
                    }.frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    historyChart.frame(minHeight: 260)
                }
                HStack {
                    ForEach(PowerState.allCases, id: \.self) { state in
                        HStack(spacing: 5) {
                            Circle().fill(color(state)).frame(width: 7, height: 7)
                            Text(state.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Text("\(count.formatted()) readings").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
            HStack {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Gaps show sleep or time when recording was unavailable. All readings stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
        .onChange(of: range) { _, _ in Task { await reload() } }
        .onChange(of: customStart) { _, _ in if range == .custom { Task { await reload() } } }
        .onChange(of: customEnd) { _, _ in if range == .custom { Task { await reload() } } }
        .onChange(of: model.revision) { _, _ in if model.historyVisible { Task { await reload() } } }
        .onChange(of: model.historyVisible) { _, visible in if visible { Task { await reload() } } }
    }

    private var historyChart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.reading.timestamp), y: .value("Battery", point.reading.percent),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(color(point.reading.state))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                if point.isolated {
                    PointMark(x: .value("Time", point.reading.timestamp), y: .value("Battery", point.reading.percent))
                        .foregroundStyle(color(point.reading.state)).symbolSize(25)
                }
            }
            if let hovered {
                RuleMark(x: .value("Selected time", hovered.timestamp))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Int(hovered.percent.rounded()))% · \(hovered.state.label)").font(.callout.weight(.semibold))
                            Text(hovered.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                PointMark(x: .value("Selected time", hovered.timestamp), y: .value("Battery", hovered.percent))
                    .foregroundStyle(color(hovered.state)).symbolSize(45)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { return }
                            let frame = geometry[anchor]
                            guard frame.contains(location),
                                  let date: Date = proxy.value(atX: location.x - frame.minX) else {
                                hovered = nil; return
                            }
                            let nearest = points.min {
                                abs($0.reading.timestamp.timeIntervalSince(date)) < abs($1.reading.timestamp.timeIntervalSince(date))
                            }?.reading
                            // Do not imply a reading exists in a long sleep gap.
                            let tolerance = max(90, domain.upperBound.timeIntervalSince(domain.lowerBound) / 600)
                            hovered = nearest.flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
                        case .ended: hovered = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Battery percentage over time")
    }

    private func metric(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption.weight(.medium)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
    }

    @MainActor private func reload() async {
        guard let store = model.store else { return }
        let token = UUID()
        generation = token
        loading = true
        hovered = nil
        do {
            let now = Date()
            let start: Date
            let end: Date
            if range == .custom {
                guard customStart < customEnd else {
                    queryError = "Choose an end date after the start date."
                    loading = false
                    return
                }
                start = customStart; end = customEnd
            } else {
                if let seconds = range.seconds {
                    start = now.addingTimeInterval(-seconds)
                } else {
                    start = try await store.firstDate() ?? now.addingTimeInterval(-86400)
                }
                end = now
            }
            let plot = try await store.chart(from: start, to: end)
            guard generation == token else { return }
            domain = start...max(end, start.addingTimeInterval(60))
            points = plot.segments.enumerated().flatMap { index, segment in
                segment.map { PlotPoint(reading: $0, segment: index, isolated: segment.count == 1) }
            }
            count = plot.sampleCount
            queryError = nil
        } catch {
            guard generation == token else { return }
            queryError = error.localizedDescription
        }
        if generation == token { loading = false }
    }

    private func color(_ state: PowerState) -> Color {
        switch state {
        case .battery: return .orange
        case .charging: return .green
        case .pluggedIn: return .blue
        }
    }
}
