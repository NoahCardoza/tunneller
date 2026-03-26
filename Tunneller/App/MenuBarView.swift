import SwiftUI

struct MenuBarView: View {
    @ObservedObject var vpnManager: VPNManager
    @Environment(\.openSettings) private var openSettings

    private let menuOpened = NotificationCenter.default.publisher(
        for: NSMenu.didBeginTrackingNotification
    )

    var body: some View {
        // Status label
        Label(vpnManager.state.statusLabel, systemImage: vpnManager.state.iconName)
            .onReceive(menuOpened) { _ in vpnManager.refreshStatus() }

        Divider()

        // Connect / status
        switch vpnManager.state {
        case .disconnected, .error:
            Button("Connect") {
                connectVPN()
            }
            .keyboardShortcut("c")
        case .connecting:
            Text("Connecting…")
        case .connected:
            Text("VPN is active")
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

    private func connectVPN() {
        if let error = vpnManager.credentialConfigurationError() {
            let alert = NSAlert()
            alert.messageText = "Credentials Not Configured"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")

            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
            return
        }

        Task {
            await vpnManager.connect()
        }
    }
}
