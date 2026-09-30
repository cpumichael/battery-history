import SwiftUI
import BatteryHistoryCore

@main
struct BatteryHistoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            if let current = model.current {
                Text("Current state · \(model.statusText)")
                if current.state == .battery {
                    let rateText = model.rate.map { String(format: "%.1f", abs($0)) + "%/hr" } ?? "Measuring…"
                    Text("Drain rate · \(rateText)")
                    if let minutes = current.timeToEmpty {
                        Text("Remaining · \(durationText(minutes))")
                    }
                }
            } else {
                Text(model.statusText)
            }
            if model.storageError != nil { Text("History could not be saved") }
            Divider()
            Button("Open History…") { model.openHistory() }.keyboardShortcut("h")
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Battery History") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.current?.state == .charging ? "battery.100percent.bolt" : "battery.75percent")
            if let current = model.current { Text("\(Int(current.percent.rounded()))%") }
        }
        Settings { SettingsView(model: model) }
    }
}

func durationText(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}
