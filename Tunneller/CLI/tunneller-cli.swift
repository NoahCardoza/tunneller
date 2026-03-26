import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "connect"

switch command {
case "connect":
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
default:
    fputs("Usage: tunneller-cli [connect]\n", stderr)
    exit(1)
}
