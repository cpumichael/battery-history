import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Start at login", isOn: Binding(
                get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                set: { model.setLaunchAtLogin($0) }))
            if model.loginStatus == .requiresApproval {
                Text("Allow Battery History in System Settings → General → Login Items.")
                    .foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = model.loginError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            LabeledContent("Collection", value: "Every minute, plus power changes")
            LabeledContent("History", value: "Kept indefinitely on this Mac")
            Text("Recording continues when the history window is closed. Sleep and time with the app quit appear as gaps.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(model.preview)
        .frame(width: 460)
        .onAppear {
            model.loginStatus = SMAppService.mainApp.status
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
