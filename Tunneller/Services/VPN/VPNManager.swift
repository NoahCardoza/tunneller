import AppKit
import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.tunneller", category: "VPNManager")

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected

    private let settings: AppSettings

    private var connectObserver: Any?
    private var activeConnection: Task<Void, Never>?
    private var activeAttemptIDs = Set<String>()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        refreshStatus()
        connectObserver = NotificationCenter.default.addObserver(
            forName: .tunnellerConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let attemptID = notification.object as? String
            Task { @MainActor in
                await self.requestConnection(attemptID: attemptID)
            }
        }
    }

    /// Refresh the connection status by querying Cisco Secure Client in the background.
    func refreshStatus() {
        Task {
            let isConnected = await Task.detached {
                VPNAutomation.checkConnectionStatus()
            }.value

            let previousState = state
            logger.info("refreshStatus called — previous: \(String(describing: previousState)), isConnected: \(isConnected)")

            if isConnected {
                state = .connected
            } else if case .connecting = state {
                // Don't override connecting state during automation
            } else {
                state = .disconnected
            }

            logger.info("refreshStatus done — new state: \(String(describing: self.state))")
        }
    }

    /// Run the full connect flow: fetch credentials → automate Cisco.
    func connect() async {
        await requestConnection(attemptID: nil)
    }

    /// All callers join the same in-flight connection and receive its terminal result.
    /// URL-scheme callers additionally receive that result through ConnectionAttemptStore.
    private func requestConnection(attemptID: String?) async {
        if let attemptID, ConnectionAttemptStore.isValid(attemptID) {
            activeAttemptIDs.insert(attemptID)
        }
        if let activeConnection {
            await activeConnection.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectOnce()
        }
        activeConnection = task
        await task.value
    }

    private func connectOnce() async {
        let outcome: ConnectionAttemptStore.Outcome

        guard VPNAutomation.isAccessibilityGranted() else {
            VPNAutomation.promptAccessibilityPermission()
            state = .error("Accessibility permission required.")
            finishConnection(.failure("accessibility-required"))
            return
        }

        state = .connecting

        do {
            let provider = makeProvider()

            let password: String
            let otp: String
            if let keychainProvider = provider as? KeychainProvider {
                // Single biometric prompt for both credentials
                let creds = try keychainProvider.fetchCredentials()
                password = creds.password
                otp = creds.otp
            } else {
                password = try await provider.fetchPassword()
                otp = try await provider.fetchOTP()
            }

            try VPNAutomation.connect(password: password, otp: otp)

            // Give Cisco a moment to finalize
            try? await Task.sleep(for: .seconds(2))

            let isConnected = await Task.detached {
                VPNAutomation.checkConnectionStatus()
            }.value

            if isConnected {
                state = .connected
                outcome = .success
            } else {
                state = .disconnected
                outcome = .failure("vpn-not-connected")
            }
        } catch CredentialError.authenticationCancelled {
            state = .disconnected
            outcome = .failure("authentication-cancelled")
        } catch CredentialError.keychainItemNotFound {
            settings.hasKeychainCredentials = false
            state = .disconnected
            showErrorAlert(CredentialError.keychainItemNotFound.localizedDescription)
            outcome = .failure("credentials-not-configured")
        } catch CredentialError.totpSeedNotConfigured {
            settings.hasKeychainCredentials = false
            state = .disconnected
            showErrorAlert(CredentialError.totpSeedNotConfigured.localizedDescription)
            outcome = .failure("totp-not-configured")
        } catch {
            state = .disconnected
            showErrorAlert(error.localizedDescription)
            outcome = .failure("connection-failed")
        }
        finishConnection(outcome)
    }

    /// Returns a descriptive error if the selected credential source is not fully configured, or `nil` if ready.
    func credentialConfigurationError() -> String? {
        switch settings.credentialSource {
        case .keychain:
            if settings.hasKeychainCredentials { return nil }
            return "Keychain credentials not configured. Save them in Settings → Credentials."

        case .onePassword:
            var missing: [String] = []
            if settings.opBinaryPath.isEmpty { missing.append("op binary path") }
            if settings.opPasswordPath.isEmpty { missing.append("password reference") }
            if settings.opOtpPath.isEmpty { missing.append("OTP reference") }
            if missing.isEmpty { return nil }
            return "1Password is not fully configured. Missing: \(missing.joined(separator: ", ")). Set them in Settings → Credentials."
        }
    }

    private func finishConnection(_ outcome: ConnectionAttemptStore.Outcome) {
        let attemptIDs = activeAttemptIDs
        activeAttemptIDs.removeAll()
        activeConnection = nil
        for attemptID in attemptIDs {
            ConnectionAttemptStore.publish(outcome, for: attemptID)
        }
    }

    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Connection Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Private

    private func makeProvider() -> CredentialProvider {
        switch settings.credentialSource {
        case .onePassword:
            OnePasswordProvider(
                opBinaryPath: settings.opBinaryPath,
                passwordPath: settings.opPasswordPath,
                otpPath: settings.opOtpPath
            )
        case .keychain:
            KeychainProvider(accountName: settings.keychainAccountName)
        }
    }
}

/// Same-user, attempt-scoped result channel used by the bundled `tun` CLI.
/// Results are terminal facts for one UUID, never a global retry cooldown.
enum ConnectionAttemptStore {
    enum Outcome {
        case success
        case failure(String)

        var serialized: String {
            switch self {
            case .success: "success\n"
            case .failure(let code): "failure:\(code)\n"
            }
        }
    }

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tunneller/connection-attempts", isDirectory: true)
    }()

    static func isValid(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    static func publish(_ outcome: Outcome, for attemptID: String) {
        guard isValid(attemptID) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent("\(attemptID).result")
            let temporary = directory.appendingPathComponent(".\(attemptID).\(UUID().uuidString).tmp")
            try outcome.serialized.data(using: .utf8)?.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            // replaceItemAt requires an existing target on some Foundation versions.
            let destination = directory.appendingPathComponent("\(attemptID).result")
            let temporary = directory.appendingPathComponent(".\(attemptID).\(UUID().uuidString).tmp")
            try? outcome.serialized.data(using: .utf8)?.write(to: temporary)
            try? FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
