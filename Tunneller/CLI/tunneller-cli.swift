import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "connect"
let waitFlag = args.contains("--wait") || args.contains("-w")
let timeout: TimeInterval = 60
let attemptsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Tunneller/connection-attempts", isDirectory: true)
let lockURL = attemptsDirectory.appendingPathComponent("connect.lock")

func checkVPNConnected() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/cisco/secureclient/bin/vpn")
    process.arguments = ["state"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .localizedCaseInsensitiveContains("state: Connected") ?? false
}

func resultURL(_ id: UUID) -> URL { attemptsDirectory.appendingPathComponent("\(id.uuidString).result") }

func readResult(_ id: UUID) -> Bool? {
    guard let value = try? String(contentsOf: resultURL(id), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if value == "success" { return true }
    if value.hasPrefix("failure:") {
        fputs("Tunneller connection failed: \(value.dropFirst(8))\n", stderr)
        return false
    }
    return nil
}

func publishFailure(_ id: UUID, _ code: String) {
    let temporary = attemptsDirectory.appendingPathComponent(".\(id.uuidString).\(UUID().uuidString).tmp")
    try? "failure:\(code)\n".data(using: .utf8)?.write(to: temporary)
    try? FileManager.default.moveItem(at: temporary, to: resultURL(id))
}

func parseLock() -> (pid: Int32, id: UUID)? {
    guard let text = try? FileManager.default.destinationOfSymbolicLink(atPath: lockURL.path) else { return nil }
    let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let pid = Int32(parts[0]), let id = UUID(uuidString: parts[1]) else { return nil }
    return (pid, id)
}

func releaseLock(_ id: UUID) {
    guard let active = parseLock(), active.pid == getpid(), active.id == id else { return }
    try? FileManager.default.removeItem(at: lockURL)
}

func waitForResult(_ id: UUID) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let result = readResult(id) { return result }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fputs("Timed out waiting for Tunneller connection attempt.\n", stderr)
    return false
}

func triggerConnect(_ id: UUID) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["tunneller://connect?attempt=\(id.uuidString)"]
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
    catch { return false }
}

func connectAndWait() -> Bool {
    if checkVPNConnected() { return true }
    try? FileManager.default.createDirectory(at: attemptsDirectory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let attempt = UUID()
    while true {
        do {
            try FileManager.default.createSymbolicLink(atPath: lockURL.path, withDestinationPath: "\(getpid()):\(attempt.uuidString)")
            guard triggerConnect(attempt) else { publishFailure(attempt, "launch-failed"); releaseLock(attempt); return false }
            let result = waitForResult(attempt)
            if !result { publishFailure(attempt, "timeout") }
            releaseLock(attempt)
            return result
        } catch {
            guard let joined = parseLock() else { continue }
            if kill(joined.pid, 0) != 0 && errno == ESRCH {
                publishFailure(joined.id, "owner-abandoned")
                try? FileManager.default.removeItem(at: lockURL)
                continue
            }
            return waitForResult(joined.id)
        }
    }
}

switch command {
case "connect":
    if waitFlag {
        guard connectAndWait() else { exit(1) }
        print("VPN connected.")
    } else if !checkVPNConnected() {
        _ = triggerConnect(UUID())
    }
case "status":
    if checkVPNConnected() { print("Connected") } else { print("Disconnected"); exit(1) }
default:
    fputs("Usage: tun <connect [--wait]|status>\n", stderr)
    exit(1)
}
