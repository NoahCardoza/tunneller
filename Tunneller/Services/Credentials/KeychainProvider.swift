import Foundation
import LocalAuthentication
import os
import Security

private let logger = Logger(subsystem: "com.tunneller", category: "Keychain")

/// Codable container for both credentials stored as a single keychain item.
private struct StoredCredentials: Codable {
    var password: String?
    var totpSeed: String?
}

struct KeychainProvider: CredentialProvider {
    let accountName: String

    private static let service = "com.tunneller"
    private static let credentialsKey = "vpn-credentials"
    // Legacy keys for migration
    private static let legacyPasswordKey = "vpn-password"
    private static let legacyTotpSeedKey = "vpn-totp-seed"

    // MARK: - CredentialProvider

    func fetchPassword() async throws -> String {
        let creds = try readCredentials(localizedReason: "Authenticate to connect VPN")
        guard let password = creds.password, !password.isEmpty else {
            throw CredentialError.keychainItemNotFound
        }
        return password
    }

    func fetchOTP() async throws -> String {
        let creds = try readCredentials(localizedReason: "Authenticate to connect VPN")
        guard let seed = creds.totpSeed, !seed.isEmpty else {
            throw CredentialError.totpSeedNotConfigured
        }
        guard let otp = TOTPGenerator.generateTOTP(secret: seed) else {
            throw CredentialError.invalidTOTPSeed
        }
        return otp
    }

    /// Fetch both password and OTP in a single biometric prompt.
    func fetchCredentials() throws -> (password: String, otp: String) {
        let creds = try readCredentials(localizedReason: "Authenticate to connect VPN")
        guard let password = creds.password, !password.isEmpty else {
            throw CredentialError.keychainItemNotFound
        }
        guard let seed = creds.totpSeed, !seed.isEmpty else {
            throw CredentialError.totpSeedNotConfigured
        }
        guard let otp = TOTPGenerator.generateTOTP(secret: seed) else {
            throw CredentialError.invalidTOTPSeed
        }
        return (password, otp)
    }

    // MARK: - Read (with biometric prompt)

    private func readCredentials(localizedReason: String) throws -> StoredCredentials {
        // Try the new combined key first
        if let creds = try readSingleItem(
            account: "\(accountName)-\(Self.credentialsKey)",
            localizedReason: localizedReason,
            decode: { data in try JSONDecoder().decode(StoredCredentials.self, from: data) }
        ) {
            return creds
        }

        // Fall back to legacy separate keys (no biometric prompt if unprotected)
        logger.info("Combined credentials not found, trying legacy keys")
        let password = try readSingleItem(
            account: "\(accountName)-\(Self.legacyPasswordKey)",
            localizedReason: localizedReason,
            decode: { data in String(data: data, encoding: .utf8) }
        )
        let seed = try readSingleItem(
            account: "\(accountName)-\(Self.legacyTotpSeedKey)",
            localizedReason: localizedReason,
            decode: { data in String(data: data, encoding: .utf8) }
        )

        guard password != nil || seed != nil else {
            throw CredentialError.keychainItemNotFound
        }

        return StoredCredentials(password: password, totpSeed: seed)
    }

    /// Read a single keychain item with biometric prompt. Returns nil if not found.
    private func readSingleItem<T>(
        account: String,
        localizedReason: String,
        decode: (Data) throws -> T?
    ) throws -> T? {
        let context = LAContext()
        context.localizedReason = localizedReason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try decode(data)
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
        return accessControl
    }

    /// Create an LAContext with interactionNotAllowed to suppress biometric UI.
    private static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    // MARK: - Static Write Helpers (used by Settings UI)

    /// Save both password and TOTP seed together as a single protected keychain item.
    @MainActor
    static func saveCredentials(password: String, totpSeed: String, accountName: String) throws {
        guard TOTPGenerator.generateTOTP(secret: totpSeed) != nil else {
            throw CredentialError.invalidTOTPSeed
        }
        let creds = StoredCredentials(password: password, totpSeed: totpSeed)
        try saveCredentialsItem(creds, accountName: accountName)
        AppSettings.shared.hasKeychainCredentials = true
    }

    // MARK: - Private Write

    private static func saveCredentialsItem(_ creds: StoredCredentials, accountName: String) throws {
        let data = try JSONEncoder().encode(creds)
        try saveKeychainItem(data: data, account: "\(accountName)-\(credentialsKey)")
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
        SecItemDelete(deleteQuery as CFDictionary)

        // Add with biometric access control
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }
    }

    // MARK: - Migration from legacy separate items

    /// Returns true if old-style separate password/TOTP items exist (unprotected, so silent read works).
    static func needsMigration(accountName: String) -> Bool {
        legacyItemExists(account: "\(accountName)-\(legacyPasswordKey)")
            || legacyItemExists(account: "\(accountName)-\(legacyTotpSeedKey)")
    }

    /// Reads old separate items and re-saves as a single combined protected item.
    @MainActor
    static func migrateToProtectedStorage(accountName: String) throws {
        let password = readLegacyItem(account: "\(accountName)-\(legacyPasswordKey)")
        let totpSeed = readLegacyItem(account: "\(accountName)-\(legacyTotpSeedKey)")

        guard password != nil || totpSeed != nil else { return }

        let creds = StoredCredentials(
            password: password,
            totpSeed: totpSeed
        )
        try saveCredentialsItem(creds, accountName: accountName)

        // Delete legacy items
        deleteLegacyItem(account: "\(accountName)-\(legacyPasswordKey)")
        deleteLegacyItem(account: "\(accountName)-\(legacyTotpSeedKey)")

        AppSettings.shared.hasKeychainCredentials = true
        logger.info("Migration complete: legacy items moved to combined protected storage")
    }

    private static func legacyItemExists(account: String) -> Bool {
        let context = silentContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func readLegacyItem(account: String) -> String? {
        let context = silentContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
