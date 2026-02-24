import SwiftUI

@main
struct CiscoAutoConnectApp: App {
    @StateObject private var vpnManager = VPNManager()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vpnManager: vpnManager, settings: settings)
        } label: {
            Image(systemName: vpnManager.state.iconName)
        }

        Settings {
            SettingsView()
        }
    }
}
