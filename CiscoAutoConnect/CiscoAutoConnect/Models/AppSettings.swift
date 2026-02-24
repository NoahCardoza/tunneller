import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Credential Source

    @AppStorage("credentialSource")
    var credentialSource: CredentialSource = .onePassword

    // MARK: - 1Password CLI

    @AppStorage("opBinaryPath")
    var opBinaryPath: String = "/opt/homebrew/bin/op"

    @AppStorage("opPasswordPath")
    var opPasswordPath: String = "op://Quicken/Okta Quicken/password"

    @AppStorage("opOtpPath")
    var opOtpPath: String = "op://Quicken/Okta Quicken/one-time password"

    // MARK: - Keychain

    @AppStorage("keychainAccountName")
    var keychainAccountName: String = "CiscoAutoConnect-VPN"

    // MARK: - General

    @AppStorage("launchAtLogin")
    var launchAtLogin: Bool = false
}
