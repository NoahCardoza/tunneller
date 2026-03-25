import Foundation
import LocalAuthentication
import os
import Security

private let logger = Logger(subsystem: "com.tunneller", category: "Keychain")

struct KeychainProvider: CredentialProvider {
    let accountName: String

    private static let service = "com.tunneller"
    private static let passwordKey = "vpn-password"
    private static let totpSeedKey = "vpn-totp-seed"

    func fetchPassword() async throws -> String {
        guard let data = try readKeychainItem(
            account: Self.passwordKey,
            localizedReason: "Authenticate to access VPN password"
        ) else {
            throw CredentialError.keychainItemNotFound
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw CredentialError.keychainItemNotFound
        }
        return password
    }

    func fetchOTP() async throws -> String {
        guard let data = try readKeychainItem(
            account: Self.totpSeedKey,
            localizedReason: "Authenticate to generate one-time code"
        ) else {
            throw CredentialError.totpSeedNotConfigured
        }
        guard let seed = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidTOTPSeed
        }
        guard let otp = TOTPGenerator.generateTOTP(secret: seed) else {
            throw CredentialError.invalidTOTPSeed
        }
        return otp
    }

    // MARK: - Keychain Helpers

    private func readKeychainItem(account: String, localizedReason: String) throws -> Data? {
        let context = LAContext()
        context.localizedReason = localizedReason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(accountName)-\(account)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled:
            throw CredentialError.authenticationCancelled
        case errSecAuthFailed:
            throw CredentialError.authenticationFailed
        default:
            throw CredentialError.keychainError(status)
        }
    }

    // MARK: - Access Control

    private static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        logger.info("Creating SecAccessControl with kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly + .userPresence")
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            let cfError = error?.takeRetainedValue()
            logger.error("SecAccessControlCreateWithFlags failed: \(cfError?.localizedDescription ?? "unknown error")")
            if let cfError {
                throw cfError as Error
            }
            throw CredentialError.keychainError(errSecParam)
        }
        logger.info("SecAccessControl created successfully")
        return accessControl
    }

    // MARK: - Static Write Helpers (used by Settings UI)

    static func savePassword(_ password: String, accountName: String) throws {
        try saveKeychainItem(
            data: Data(password.utf8),
            account: "\(accountName)-\(passwordKey)"
        )
    }

    static func saveTOTPSeed(_ seed: String, accountName: String) throws {
        // Validate seed before saving
        guard TOTPGenerator.generateTOTP(secret: seed) != nil else {
            throw CredentialError.invalidTOTPSeed
        }
        try saveKeychainItem(
            data: Data(seed.utf8),
            account: "\(accountName)-\(totpSeedKey)"
        )
    }

    static func hasPassword(accountName: String) -> Bool {
        hasKeychainItem(account: "\(accountName)-\(passwordKey)")
    }

    static func hasTOTPSeed(accountName: String) -> Bool {
        hasKeychainItem(account: "\(accountName)-\(totpSeedKey)")
    }

    private static func saveKeychainItem(data: Data, account: String) throws {
        logger.info("saveKeychainItem: account=\(account)")

        let accessControl = try makeAccessControl()

        // Delete any existing item first (SecItemUpdate cannot change access control)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        logger.info("SecItemDelete status: \(deleteStatus) (\(SecCopyErrorMessageString(deleteStatus, nil) as String? ?? "unknown"))")

        // Add with biometric access control
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]
        logger.info("SecItemAdd attempting with kSecAttrAccessControl")

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        logger.info("SecItemAdd status: \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "unknown"))")

        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }
    }

    private static func hasKeychainItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means item exists but requires auth to read
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Migration

    /// Returns true if either the password or TOTP seed exists but lacks biometric access control.
    static func needsMigration(accountName: String) -> Bool {
        itemNeedsMigration(account: "\(accountName)-\(passwordKey)")
            || itemNeedsMigration(account: "\(accountName)-\(totpSeedKey)")
    }

    /// Reads old unprotected items and re-saves them with biometric access control.
    static func migrateToProtectedStorage(accountName: String) throws {
        try migrateItemIfNeeded(
            account: "\(accountName)-\(passwordKey)"
        )
        try migrateItemIfNeeded(
            account: "\(accountName)-\(totpSeedKey)"
        )
    }

    /// Check if a single item is stored without access control.
    /// Uses kSecUseAuthenticationUIFail to prevent any UI prompt —
    /// if the read succeeds, the item has no access control (old format).
    /// If it fails with errSecInteractionNotAllowed, it's already protected.
    private static func itemNeedsMigration(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // If read succeeds without auth, item is unprotected → needs migration
        return status == errSecSuccess
    }

    private static func migrateItemIfNeeded(account: String) throws {
        // Read old item without auth (only works if unprotected)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            // Item doesn't exist or is already protected — nothing to migrate
            return
        }

        // Re-save with access control (saveKeychainItem deletes first, then adds with protection)
        try saveKeychainItem(data: data, account: account)
    }
}
