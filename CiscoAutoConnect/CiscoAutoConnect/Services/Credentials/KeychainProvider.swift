import Foundation
import Security

struct KeychainProvider: CredentialProvider {
    let accountName: String

    private static let service = "com.ciscoautoconnect"
    private static let passwordKey = "vpn-password"
    private static let totpSeedKey = "vpn-totp-seed"

    func fetchPassword() async throws -> String {
        guard let data = try readKeychainItem(account: Self.passwordKey) else {
            throw CredentialError.keychainItemNotFound
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw CredentialError.keychainItemNotFound
        }
        return password
    }

    func fetchOTP() async throws -> String {
        guard let data = try readKeychainItem(account: Self.totpSeedKey) else {
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

    private func readKeychainItem(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(accountName)-\(account)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }

        return result as? Data
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try to update first
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Add new item
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw CredentialError.keychainError(updateStatus)
        }
    }

    private static func hasKeychainItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
