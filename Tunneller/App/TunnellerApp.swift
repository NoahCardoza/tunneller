import SwiftUI

@main
struct TunnellerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vpnManager = VPNManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vpnManager: vpnManager)
        } label: {
            Image(systemName: vpnManager.state.iconName)
        }

        Settings {
            SettingsView()
        }
    }
}
