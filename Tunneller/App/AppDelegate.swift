import AppKit
import Foundation

/// Launch Services can deliver URLs before SwiftUI initializes the manager.
/// Buffer those requests until a consumer registers, then deliver them once.
@MainActor
final class ConnectionRequestRouter {
    static let shared = ConnectionRequestRouter()
    private var pending: [String?] = []
    private var handler: ((String?) -> Void)?

    func send(attemptID: String?) {
        if let handler { handler(attemptID) }
        else { pending.append(attemptID) }
    }

    func register(_ handler: @escaping (String?) -> Void) {
        self.handler = handler
        let requests = pending
        pending.removeAll()
        for request in requests { handler(request) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "tunneller" else { continue }
            switch url.host {
            case "connect":
                let attemptID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "attempt" })?.value
                ConnectionRequestRouter.shared.send(attemptID: attemptID)
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
