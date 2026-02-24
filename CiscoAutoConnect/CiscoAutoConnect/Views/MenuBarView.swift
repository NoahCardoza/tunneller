import SwiftUI

struct MenuBarView: View {
    @ObservedObject var vpnManager: VPNManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            Label(vpnManager.state.statusLabel, systemImage: vpnManager.state.iconName)
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            Divider()

            // Connect / Disconnect
            switch vpnManager.state {
            case .disconnected, .error:
                Button("Connect") {
                    Task { await vpnManager.connect() }
                }
                .keyboardShortcut("c")
            case .connecting:
                Button("Connecting…") {}
                    .disabled(true)
            case .connected:
                Text("VPN is active")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            Divider()

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}
