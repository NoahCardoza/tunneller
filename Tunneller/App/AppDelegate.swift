import AppKit
import Foundation

/// Launch Services can deliver URLs before SwiftUI initializes the manager.
/// Buffer those requests until a consumer registers, then deliver them once.
@MainActor
final class ConnectionRequestRouter {
    static let shared = ConnectionRequestRouter()
    private var pending: [ConnectionRequest] = []
    private var handler: ((ConnectionRequest) -> Void)?
    private var terminationHandler: (() -> Void)?
    private let diagnostics: ConnectionDiagnostics

    init(diagnostics: ConnectionDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    func send(attemptID: String?) {
        send(ConnectionRequest(attemptID: attemptID))
    }

    func send(_ request: ConnectionRequest) {
        if let handler {
            diagnostics.record(.urlHandled, component: .app, request: request)
            handler(request)
        } else {
            diagnostics.record(.urlQueued, component: .app, request: request)
            pending.append(request)
        }
    }

    func register(_ handler: @escaping (ConnectionRequest) -> Void, onTermination: (() -> Void)? = nil) {
        self.handler = handler
        terminationHandler = onTermination
        let requests = pending
        pending.removeAll()
        for request in requests {
            diagnostics.record(.urlHandled, component: .app, request: request)
            handler(request)
        }
    }

    func applicationWillTerminate() {
        terminationHandler?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "tunneller" else { continue }
            switch url.host {
            case "connect":
                let request = Self.connectionRequest(from: url)
                ConnectionDiagnostics.shared.record(.urlReceived, component: .app, request: request)
                ConnectionRequestRouter.shared.send(request)
            default:
                break
            }
        }
    }

    static func connectionRequest(from url: URL) -> ConnectionRequest {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let value: (String) -> String? = { name in items?.first(where: { $0.name == name })?.value }
        let wait: Bool? = value("wait") == "1" ? true : (value("wait") == "0" ? false : nil)
        return ConnectionRequest(attemptID: value("attempt"),
            requestID: value("request").flatMap(UUID.init(uuidString:)) ?? UUID(),
            correlationID: DiagnosticCorrelationID(value("correlation")), wait: wait)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConnectionDiagnostics.shared.record(.appLaunched, component: .app)
        // Auto-discover op binary path on first launch
        let settings = AppSettings.shared
        if !settings.hasRunOpDiscovery {
            if let path = OnePasswordProvider.discoverOpBinaryPath() {
                settings.opBinaryPath = path
            }
            settings.hasRunOpDiscovery = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConnectionRequestRouter.shared.applicationWillTerminate()
        ConnectionDiagnostics.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
