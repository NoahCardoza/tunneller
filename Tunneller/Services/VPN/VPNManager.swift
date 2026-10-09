import AppKit
import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.tunneller", category: "VPNManager")

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected

    private let settings: AppSettings

    private var activeConnection: Task<Void, Never>?
    private var activeAttemptIDs = Set<UUID>()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        refreshStatus()
        ConnectionRequestRouter.shared.register { [weak self] attemptID in
            guard let self else { return }
            _ = self.connectionTask(attemptID: attemptID)
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
        await connectionTask(attemptID: nil)?.value
    }

    /// All callers join the same in-flight connection and receive its terminal result.
    /// URL-scheme callers additionally receive that result through ConnectionAttemptStore.
    private func connectionTask(attemptID: String?) -> Task<Void, Never>? {
        if let attemptID {
            guard let id = UUID(uuidString: attemptID) else { return nil }
            do {
                guard try ConnectionAttemptStore.shared.isPending(id) else { return nil }
                activeAttemptIDs.insert(id)
            } catch {
                logger.error("Cannot join CLI attempt: \(error.localizedDescription)")
                return nil
            }
        }
        if let activeConnection {
            return activeConnection
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectOnce()
        }
        activeConnection = task
        return task
    }

    private func connectOnce() async {
        let alreadyConnected = await Task.detached { VPNAutomation.checkConnectionStatus() }.value
        if alreadyConnected {
            state = .connected
            finishConnection(.success)
            return
        }
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
            finishConnection(.failure("credentials-not-configured"))
            showErrorAlert(CredentialError.keychainItemNotFound.localizedDescription)
            return
        } catch CredentialError.totpSeedNotConfigured {
            settings.hasKeychainCredentials = false
            state = .disconnected
            finishConnection(.failure("totp-not-configured"))
            showErrorAlert(CredentialError.totpSeedNotConfigured.localizedDescription)
            return
        } catch {
            state = .disconnected
            finishConnection(.failure("connection-failed"))
            showErrorAlert(error.localizedDescription)
            return
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
            do { try ConnectionAttemptStore.shared.complete(outcome, for: attemptID) }
            catch { logger.error("Cannot publish CLI result: \(error.localizedDescription)") }
        }
    }

    private func showErrorAlert(_ message: String) {
        // Complete the shared task before entering the modal event loop.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Connection Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
