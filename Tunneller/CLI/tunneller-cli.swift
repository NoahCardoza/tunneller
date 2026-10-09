import Darwin
import Foundation

@main
enum TunnellerCLI {
    static func main() {
        let status = run()
        ConnectionDiagnostics.shared.flush()
        if status != 0 { exit(status) }
    }

    private static func run() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "connect"
        let waitFlag = args.contains("--wait") || args.contains("-w")
        switch command {
        case "connect":
            let request = ConnectionRequest(attemptID: nil,
                correlationID: DiagnosticCorrelationID(ProcessInfo.processInfo.environment["TUNNELLER_ATTEMPT_ID"]),
                wait: waitFlag)
            ConnectionDiagnostics.shared.record(.cliInvocation, component: .cli, request: request)
            if waitFlag {
                guard connectAndWait(request) else { return 1 }
                print("VPN connected.")
            } else if checkVPNConnected() {
                ConnectionDiagnostics.shared.record(.connectedFastPath, component: .cli, request: request)
                ConnectionDiagnostics.shared.record(.terminal, component: .cli, request: request,
                    terminal: .init(result: .success))
            } else if !triggerConnect(request) {
                ConnectionDiagnostics.shared.record(.terminal, component: .cli, request: request,
                    terminal: .init(result: .failure, reason: .launchFailed))
                fputs("Could not launch Tunneller.\n", stderr)
                return 1
            }
        case "status":
            if checkVPNConnected() { print("Connected") }
            else { print("Disconnected"); return 1 }
        default:
            // Classify the rejected invocation without copying its arguments.
            ConnectionDiagnostics.shared.record(.cliRejected, component: .cli)
            fputs("Usage: tun <connect [--wait]|status>\n", stderr)
            return 1
        }
        return 0
    }

    private static func checkVPNConnected() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/cisco/secureclient/bin/vpn")
        process.arguments = ["state"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: output, encoding: .utf8)?.localizedCaseInsensitiveContains("state: Connected") ?? false
    }

    private static func triggerConnect(_ request: ConnectionRequest, attemptID: UUID? = nil) -> Bool {
        ConnectionDiagnostics.shared.record(.launchRequested, component: .cli, request: request, attemptID: attemptID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var components = URLComponents()
        components.scheme = "tunneller"
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "request", value: request.requestID.uuidString),
            URLQueryItem(name: "correlation", value: request.correlationID.value),
            URLQueryItem(name: "wait", value: request.wait == true ? "1" : "0")]
        if let attemptID { components.queryItems?.append(URLQueryItem(name: "attempt", value: attemptID.uuidString)) }
        guard let url = components.url else { return false }
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            let accepted = process.terminationStatus == 0
            if accepted {
                ConnectionDiagnostics.shared.record(.launchAccepted, component: .cli, request: request, attemptID: attemptID)
            }
            return accepted
        }
        catch { return false }
    }

    private static func connectAndWait(_ request: ConnectionRequest) -> Bool {
        if checkVPNConnected() {
            ConnectionDiagnostics.shared.record(.connectedFastPath, component: .cli, request: request)
            ConnectionDiagnostics.shared.record(.terminal, component: .cli, request: request,
                terminal: .init(result: .success))
            return true
        }
        let store = ConnectionAttemptStore.shared
        var attemptID: UUID?
        do {
            let registration = try store.joinOrCreate()
            attemptID = registration.attempt.id
            ConnectionDiagnostics.shared.record(registration.isOwner ? .attemptOwner : .attemptJoiner,
                component: .cli, request: request, attemptID: registration.attempt.id)
            if registration.isOwner && !triggerConnect(request, attemptID: registration.attempt.id) {
                try store.complete(.failure("launch-failed"), for: registration.attempt.id)
            }
            let outcome = try store.wait(for: registration)
            ConnectionDiagnostics.shared.record(.terminal, component: .cli, request: request,
                attemptID: registration.attempt.id, terminal: .init(outcome))
            switch outcome {
            case .success: return true
            case .failure(let code):
                fputs("Tunneller connection failed: \(code)\n", stderr)
                return false
            }
        } catch {
            ConnectionDiagnostics.shared.record(.terminal, component: .cli, request: request,
                attemptID: attemptID, terminal: .init(result: .failure, reason: .coordinationFailed))
            fputs("Tunneller connection coordination failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
