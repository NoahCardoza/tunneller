import SwiftUI

struct CredentialSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    // Keychain entry fields (not persisted directly — written to Keychain on save)
    @State private var keychainPassword = ""
    @State private var keychainTOTPSeed = ""
    @State private var keychainSaveError: String?
    @State private var keychainSaveSuccess = false
    @State private var hasStoredPassword = false
    @State private var hasStoredTOTPSeed = false

    var body: some View {
        Form {
            Section("Credential Source") {
                Picker("Source", selection: $settings.credentialSource) {
                    ForEach(CredentialSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch settings.credentialSource {
            case .onePassword:
                onePasswordSection
            case .keychain:
                keychainSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refreshKeychainStatus)
    }

    // MARK: - 1Password Section

    private var onePasswordSection: some View {
        Section("1Password Paths") {
            LabeledContent("Password") {
                TextField("op:// path", text: $settings.opPasswordPath)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("OTP") {
                TextField("op:// path", text: $settings.opOtpPath)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Use the 1Password reference format: op://vault/item/field")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Keychain Section

    private var keychainSection: some View {
        Section("Keychain Storage") {
            LabeledContent("Password") {
                HStack {
                    SecureField("VPN password", text: $keychainPassword)
                        .textFieldStyle(.roundedBorder)
                    if hasStoredPassword {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Password is stored in Keychain")
                    }
                }
            }

            LabeledContent("TOTP Seed") {
                HStack {
                    SecureField("Base32 secret key", text: $keychainTOTPSeed)
                        .textFieldStyle(.roundedBorder)
                    if hasStoredTOTPSeed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("TOTP seed is stored in Keychain")
                    }
                }
            }

            Text("Paste the TOTP setup key (base32 encoded) from your authenticator setup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save to Keychain") {
                    saveToKeychain()
                }
                .disabled(keychainPassword.isEmpty && keychainTOTPSeed.isEmpty)

                if keychainSaveSuccess {
                    Text("Saved!")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                if let error = keychainSaveError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func saveToKeychain() {
        keychainSaveError = nil
        keychainSaveSuccess = false

        do {
            if !keychainPassword.isEmpty {
                try KeychainProvider.savePassword(keychainPassword, accountName: settings.keychainAccountName)
                keychainPassword = ""
            }
            if !keychainTOTPSeed.isEmpty {
                try KeychainProvider.saveTOTPSeed(keychainTOTPSeed, accountName: settings.keychainAccountName)
                keychainTOTPSeed = ""
            }
            keychainSaveSuccess = true
            refreshKeychainStatus()
        } catch {
            keychainSaveError = error.localizedDescription
        }
    }

    private func refreshKeychainStatus() {
        hasStoredPassword = KeychainProvider.hasPassword(accountName: settings.keychainAccountName)
        hasStoredTOTPSeed = KeychainProvider.hasTOTPSeed(accountName: settings.keychainAccountName)
    }
}
