import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-discover op binary path on first launch
        let settings = AppSettings.shared
        if !settings.hasRunOpDiscovery {
            if let path = OnePasswordProvider.discoverOpBinaryPath() {
                settings.opBinaryPath = path
            }
            settings.hasRunOpDiscovery = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
