import Darwin
import Foundation

@main
enum TunnellerCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "connect"
        let waitFlag = args.contains("--wait") || args.contains("-w")
        switch command {
        case "connect":
            if waitFlag {
                guard connectAndWait() else { exit(1) }
                print("VPN connected.")
            } else if !checkVPNConnected() && !triggerConnect() {
                fputs("Could not launch Tunneller.\n", stderr)
                exit(1)
            }
        case "status":
            if checkVPNConnected() { print("Connected") }
            else { print("Disconnected"); exit(1) }
        default:
            fputs("Usage: tun <connect [--wait]|status>\n", stderr)
            exit(1)
        }
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

    private static func triggerConnect(_ id: UUID? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [id.map { "tunneller://connect?attempt=\($0.uuidString)" } ?? "tunneller://connect"]
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private static func connectAndWait() -> Bool {
        if checkVPNConnected() { return true }
        let store = ConnectionAttemptStore.shared
        do {
            let registration = try store.joinOrCreate()
            if registration.isOwner && !triggerConnect(registration.attempt.id) {
                try store.complete(.failure("launch-failed"), for: registration.attempt.id)
            }
            switch try store.wait(for: registration) {
            case .success: return true
            case .failure(let code):
                fputs("Tunneller connection failed: \(code)\n", stderr)
                return false
            }
        } catch {
            fputs("Tunneller connection coordination failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
