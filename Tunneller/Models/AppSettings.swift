import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Credential Source

    @AppStorage("credentialSource")
    var credentialSource: CredentialSource = .keychain

    // MARK: - 1Password CLI

    @AppStorage("opBinaryPath")
    var opBinaryPath: String = ""

    @AppStorage("opPasswordPath")
    var opPasswordPath: String = ""

    @AppStorage("opOtpPath")
    var opOtpPath: String = ""

    @AppStorage("hasRunOpDiscovery")
    var hasRunOpDiscovery: Bool = false

    // MARK: - Keychain

    @AppStorage("keychainAccountName")
    var keychainAccountName: String = "Tunneller-VPN"

    @AppStorage("hasKeychainCredentials")
    var hasKeychainCredentials: Bool = false

    // MARK: - General

    @AppStorage("launchAtLogin")
    var launchAtLogin: Bool = false
}
