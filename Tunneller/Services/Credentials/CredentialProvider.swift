import Foundation

protocol CredentialProvider {
    func fetchPassword() async throws -> String
    func fetchOTP() async throws -> String
}
