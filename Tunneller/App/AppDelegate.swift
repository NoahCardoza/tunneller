import AppKit

extension Notification.Name {
    static let tunnellerConnect = Notification.Name("tunnellerConnect")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "tunneller" else { continue }
            switch url.host {
            case "connect":
                NotificationCenter.default.post(name: .tunnellerConnect, object: nil)
            default:
                break
            }
        }
    }

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
