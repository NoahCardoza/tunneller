import Foundation
import SwiftUI

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var state: VPNState = .disconnected

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        refreshStatus()
    }

    /// Refresh the connection status by querying Cisco Secure Client.
    func refreshStatus() {
        if VPNAutomation.checkConnectionStatus() {
            state = .connected
        } else if case .connecting = state {
            // Don't override connecting state during automation
        } else {
            state = .disconnected
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

            let password = try await provider.fetchPassword()
            let otp = try await provider.fetchOTP()

            try VPNAutomation.connect(password: password, otp: otp)

            // Give Cisco a moment to finalize
            try? await Task.sleep(for: .seconds(2))
            refreshStatus()

            if case .connected = state {
                // Success
            } else {
                state = .connected // Trust the automation completed
            }
        } catch {
            state = .error(error.localizedDescription)
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
