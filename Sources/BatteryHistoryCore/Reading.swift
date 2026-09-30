import Foundation

public enum PowerState: String, CaseIterable, Sendable {
    case battery, charging, pluggedIn

    public var label: String {
        switch self {
        case .battery: return "On battery"
        case .charging: return "Charging"
        case .pluggedIn: return "Plugged in"
        }
    }
}

public struct BatteryReading: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let percent: Double
    public let state: PowerState
    public let session: UUID
    public let timeToEmpty: Int?
    public let timeToFull: Int?

    public init(id: UUID = UUID(), timestamp: Date, percent: Double, state: PowerState,
                session: UUID, timeToEmpty: Int? = nil, timeToFull: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.percent = percent
        self.state = state
        self.session = session
        self.timeToEmpty = timeToEmpty
        self.timeToFull = timeToFull
    }

    public var estimatedMinutes: Int? {
        switch state {
        case .battery: return timeToEmpty
        case .charging: return timeToFull
        case .pluggedIn: return nil
        }
    }
}

public enum HistoryAnalysis {
    public static let maximumGap: TimeInterval = 180

    /// Rate in percentage points per hour for the latest uninterrupted state.
    public static func rate(_ readings: [BatteryReading]) -> Double? {
        guard let last = readings.last, last.state != .pluggedIn else { return nil }
        var segment = [last]
        for reading in readings.dropLast().reversed() {
            guard reading.session == last.session, reading.state == last.state,
                  last.timestamp.timeIntervalSince(reading.timestamp) <= 1800,
                  let next = segment.last,
                  next.timestamp.timeIntervalSince(reading.timestamp) <= maximumGap,
                  next.timestamp > reading.timestamp else { break }
            segment.append(reading)
        }
        guard let first = segment.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 600 else { return nil }
        // Least-squares slope is less sensitive to a single rounded percentage reading.
        let xs = segment.map { $0.timestamp.timeIntervalSince(first.timestamp) / 3600 }
        let ys = segment.map(\.percent)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / denominator
        guard (last.state == .battery && slope < 0) || (last.state == .charging && slope > 0) else { return nil }
        return slope
    }

    public static func segments(_ readings: [BatteryReading]) -> [[BatteryReading]] {
        var result: [[BatteryReading]] = []
        for reading in readings {
            if let previous = result.last?.last,
               previous.session == reading.session,
               previous.state == reading.state,
               reading.timestamp > previous.timestamp,
               reading.timestamp.timeIntervalSince(previous.timestamp) <= maximumGap {
                result[result.count - 1].append(reading)
            } else {
                result.append([reading])
            }
        }
        return result
    }

    /// Keep endpoints and bucket extrema per segment, never bridging gaps or state changes.
    public static func reduced(_ readings: [BatteryReading], buckets: Int = 600) -> [[BatteryReading]] {
        guard let first = readings.first, let last = readings.last else { return [] }
        let width = max(1, last.timestamp.timeIntervalSince(first.timestamp) / Double(max(1, buckets)))
        return segments(readings).map { segment in
            var kept: [UUID: BatteryReading] = [:]
            if let start = segment.first { kept[start.id] = start }
            if let end = segment.last { kept[end.id] = end }
            let groups = Dictionary(grouping: segment) {
                Int($0.timestamp.timeIntervalSince(first.timestamp) / width)
            }
            for points in groups.values {
                for point in [points.first, points.last, points.min(by: { $0.percent < $1.percent }),
                              points.max(by: { $0.percent < $1.percent })].compactMap({ $0 }) {
                    kept[point.id] = point
                }
            }
            return kept.values.sorted { $0.timestamp < $1.timestamp }
        }
    }
}
