import Foundation

enum CredentialSource: String, CaseIterable, Identifiable {
    case onePassword = "onePassword"
    case keychain = "keychain"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onePassword: "1Password CLI"
        case .keychain: "macOS Keychain"
        }
    }
}
