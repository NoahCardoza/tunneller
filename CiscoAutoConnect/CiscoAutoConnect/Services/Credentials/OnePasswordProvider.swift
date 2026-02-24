import Foundation

struct OnePasswordProvider: CredentialProvider {
    let opBinaryPath: String
    let passwordPath: String
    let otpPath: String

    func fetchPassword() async throws -> String {
        try await runOp(arguments: ["read", passwordPath])
    }

    func fetchOTP() async throws -> String {
        try await runOp(arguments: ["read", "\(otpPath)?attribute=otp"])
    }

    // MARK: - Private

    private func runOp(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.execute(binary: opBinaryPath, arguments: arguments)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(binary: String, arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw CredentialError.opNotFound(binary)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CredentialError.opCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CredentialError: LocalizedError {
    case opNotFound(String)
    case opCommandFailed(String)
    case keychainItemNotFound
    case keychainError(OSStatus)
    case totpSeedNotConfigured
    case invalidTOTPSeed

    var errorDescription: String? {
        switch self {
        case .opNotFound(let path):
            "1Password CLI not found at \(path). Install it or update the path in Settings."
        case .opCommandFailed(let message):
            "1Password CLI error: \(message)"
        case .keychainItemNotFound:
            "Password not found in Keychain. Configure it in Settings."
        case .keychainError(let status):
            "Keychain error (OSStatus \(status))."
        case .totpSeedNotConfigured:
            "TOTP seed not configured. Add it in Settings."
        case .invalidTOTPSeed:
            "Invalid TOTP seed. Check the value in Settings."
        }
    }
}
