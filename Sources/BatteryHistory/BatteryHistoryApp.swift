import SwiftUI
import BatteryHistoryCore

@main
struct BatteryHistoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text(model.statusText)
            if let current = model.current, let minutes = current.estimatedMinutes {
                Text("\(durationText(minutes)) \(current.state == .charging ? "until full" : "remaining")")
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
