import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.tunneller", category: "VPNManager")

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        refreshStatus()
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
        switch state {
        case .disconnected, .error:
            break
        default:
            return
        }

        guard VPNAutomation.isAccessibilityGranted() else {
            VPNAutomation.promptAccessibilityPermission()
            state = .error("Accessibility permission required.")
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
            } else {
                state = .connected // Trust the automation completed
            }
        } catch CredentialError.authenticationCancelled {
            // User intentionally cancelled — return to disconnected, not error
            state = .disconnected
        } catch CredentialError.keychainItemNotFound {
            settings.hasKeychainCredentials = false
            state = .error(CredentialError.keychainItemNotFound.localizedDescription)
        } catch CredentialError.totpSeedNotConfigured {
            settings.hasKeychainCredentials = false
            state = .error(CredentialError.totpSeedNotConfigured.localizedDescription)
        } catch {
            state = .error(error.localizedDescription)
        }
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
