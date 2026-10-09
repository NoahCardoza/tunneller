import Darwin
import Foundation

/// Only opaque identifiers cross the diagnostic boundary. Never accept arbitrary
/// URL parameters, environment values, error descriptions, or command arguments.
struct DiagnosticCorrelationID: Equatable {
    let value: String

    init?(_ value: String?) {
        guard let value else { return nil }
        if let uuid = UUID(uuidString: value) {
            self.value = uuid.uuidString
        } else if value.hasPrefix("attempt."), value.utf8.count == 18,
                  value.dropFirst(8).utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  }) {
            self.value = value
        } else {
            return nil
        }
    }
}

struct ConnectionRequest {
    let attemptID: String?
    let requestID: UUID
    let correlationID: DiagnosticCorrelationID
    let wait: Bool?

    init(attemptID: String?, requestID: UUID = UUID(),
         correlationID: DiagnosticCorrelationID? = nil, wait: Bool? = nil) {
        self.attemptID = attemptID
        self.requestID = requestID
        self.correlationID = correlationID ?? DiagnosticCorrelationID(requestID.uuidString)!
        self.wait = wait
    }
}

/// A bounded, asynchronous JSON-lines timeline shared by the app and CLI.
/// Writers never wait for another process; contention and I/O errors drop entries.
final class ConnectionDiagnostics {
    static let shared = ConnectionDiagnostics()

    enum Component: String, Codable { case cli, app, store }
    enum Event: String, Codable {
        case cliInvocation = "cli_invocation"
        case cliRejected = "cli_rejected"
        case connectedFastPath = "connected_fast_path"
        case attemptOwner = "attempt_owner"
        case attemptJoiner = "attempt_joiner"
        case launchRequested = "launch_requested"
        case launchAccepted = "launch_accepted"
        case urlReceived = "url_received"
        case urlQueued = "url_queued"
        case urlHandled = "url_handled"
        case appLaunched = "app_launched"
        case requestIgnored = "request_ignored"
        case menuRequest = "menu_request"
        case connectionJoined = "connection_joined"
        case connectionStart = "connection_start"
        case credentialsStart = "credentials_start"
        case automationStart = "automation_start"
        case terminal
        case attemptTerminal = "attempt_terminal"
    }
    enum Result: String, Codable { case success, failure, timeout, abandoned }
    enum Reason: String, Codable {
        case launchFailed = "launch-failed"
        case coordinationFailed = "coordination-failed"
        case accessibilityRequired = "accessibility-required"
        case vpnNotConnected = "vpn-not-connected"
        case authenticationCancelled = "authentication-cancelled"
        case credentialsNotConfigured = "credentials-not-configured"
        case totpNotConfigured = "totp-not-configured"
        case connectionFailed = "connection-failed"
        case invalidAttempt = "invalid-attempt"
        case completedAttempt = "completed-attempt"
    }

    struct Terminal {
        let result: Result
        let reason: Reason?

        init(_ outcome: ConnectionAttemptStore.Outcome) {
            switch outcome {
            case .success: result = .success; reason = nil
            case .failure("timeout"): result = .timeout; reason = nil
            case .failure("owner-abandoned"): result = .abandoned; reason = nil
            case .failure(let code):
                result = .failure
                reason = Reason(rawValue: code) ?? .connectionFailed
            }
        }

        init(result: Result, reason: Reason? = nil) {
            self.result = result
            self.reason = reason
        }
    }

    private struct Entry: Encodable {
        let timestamp: String
        let component: Component
        let event: Event
        let pid: Int32
        let ppid: Int32
        let requestID: String?
        let attemptID: String?
        let connectionID: String?
        let correlationID: String?
        let wait: Bool?
        let result: Result?
        let reason: Reason?

        enum CodingKeys: String, CodingKey {
            case timestamp, component, event, pid, ppid, wait, result, reason
            case requestID = "request_id", attemptID = "attempt_id", correlationID = "correlation_id"
            case connectionID = "connection_id"
        }
    }

    let directory: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "com.tunneller.connection-diagnostics", qos: .utility)
    private let capacity = DispatchSemaphore(value: 128)

    init(directory: URL? = nil, maximumBytes: Int = 1_048_576) {
        self.directory = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tunneller", isDirectory: true)
        self.maximumBytes = max(512, maximumBytes)
    }

    func record(_ event: Event, component: Component, request: ConnectionRequest? = nil,
                attemptID: UUID? = nil, connectionID: UUID? = nil,
                terminal: Terminal? = nil, reason: Reason? = nil) {
        guard capacity.wait(timeout: .now()) == .success else { return }
        let timestamp = Date()
        let pid = getpid(), ppid = getppid()
        queue.async { [self] in
            defer { capacity.signal() }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let entry = Entry(timestamp: formatter.string(from: timestamp), component: component,
                event: event, pid: pid, ppid: ppid, requestID: request?.requestID.uuidString,
                attemptID: attemptID?.uuidString ?? request?.attemptID.flatMap(UUID.init(uuidString:))?.uuidString
                    ?? request?.requestID.uuidString,
                connectionID: connectionID?.uuidString,
                correlationID: request?.correlationID.value, wait: request?.wait,
                result: terminal?.result, reason: terminal?.reason ?? reason)
            guard var data = try? JSONEncoder().encode(entry) else { return }
            data.append(0x0a)
            write(data)
        }
    }

    /// Shutdown drain, after CLI work finishes or the app is quitting. Never extend a
    /// connection operation to wait for diagnostics or a contending log writer.
    func flush(timeout: TimeInterval = 0.1) {
        let finished = DispatchSemaphore(value: 0)
        queue.async { finished.signal() }
        _ = finished.wait(timeout: .now() + timeout)
    }

    private func write(_ data: Data) {
        guard data.count <= maximumBytes else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(), chmod(directory.path, 0o700) == 0 else { return }
            let lock = open(directory.appendingPathComponent("timeline.lock").path,
                            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lock >= 0 else { return }
            defer { close(lock) }
            guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
            let current = directory.appendingPathComponent("timeline.jsonl")
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else { return }
                if info.st_size + off_t(data.count) > maximumBytes {
                    let older = directory.appendingPathComponent("timeline.2.jsonl")
                    let previous = directory.appendingPathComponent("timeline.1.jsonl")
                    // rename replaces a directory entry without following symlinks.
                    if rename(previous.path, older.path) != 0 && errno != ENOENT { return }
                    guard rename(current.path, previous.path) == 0 else { return }
                }
            }
            let file = open(current.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard file >= 0 else { return }
            defer { close(file) }
            guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), fchmod(file, 0o600) == 0 else { return }
            // One bounded write; failures intentionally do not enter the app's
            // error handling or retry paths.
            _ = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        } catch { /* Diagnostics must never change a connection result. */ }
    }
}
