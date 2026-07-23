import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            settings.launchAtLogin = newValue
                        } catch {
                            launchAtLogin = !newValue // revert
                        }
                    }
            }

            Section("VPN Authentication") {
                HStack {
                    Text("MFA method number")
                    Spacer()
                    TextField("", text: $settings.mfaMethodNumber, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                }

                Text("If Cisco asks you to choose an MFA method after entering your password, enter its number here (for example, 2). Leave blank to skip this step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                HStack {
                    if VPNAutomation.isAccessibilityGranted() {
                        Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Grant Access…") {
                            VPNAutomation.promptAccessibilityPermission()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
