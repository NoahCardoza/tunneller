import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "connect"
let waitFlag = args.contains("--wait") || args.contains("-w")

func checkVPNConnected() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/cisco/secureclient/bin/vpn")
    process.arguments = ["state"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return false
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.localizedCaseInsensitiveContains("state: Connected")
}

func triggerConnect() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["tunneller://connect"]
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            fputs("Failed to open tunneller://connect\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

switch command {
case "connect":
    if checkVPNConnected() {
        print("VPN is already connected.")
        exit(0)
    }

    triggerConnect()

    if waitFlag {
        let timeout: TimeInterval = 60
        let start = Date()
        while !checkVPNConnected() {
            if Date().timeIntervalSince(start) > timeout {
                fputs("Timed out waiting for VPN connection.\n", stderr)
                exit(1)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        print("VPN connected.")
    }
case "status":
    if checkVPNConnected() {
        print("Connected")
    } else {
        print("Disconnected")
        exit(1)
    }
default:
    fputs("Usage: tun <connect [--wait]|status>\n", stderr)
    exit(1)
}
