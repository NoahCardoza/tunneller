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
    @State private var showOpNotFoundAlert = false

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
        Section("1Password CLI") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("op Binary")
                        .font(.headline)
                    HStack {
                        TextField("", text: $settings.opBinaryPath)
                            .textFieldStyle(.roundedBorder).labelsHidden()
                        Button("Find") {
                            if let path = OnePasswordProvider.discoverOpBinaryPath() {
                                settings.opBinaryPath = path
                            } else {
                                showOpNotFoundAlert = true
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.headline)
                    TextField("", text: $settings.opPasswordPath)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Text("e.g. op://vault/item/password")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("OTP")
                        .font(.headline)
                    TextField("", text: $settings.opOtpPath)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Text("e.g. op://vault/item/one-time password")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("1Password CLI Not Found", isPresented: $showOpNotFoundAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The 1Password CLI (op) could not be found. Install it from https://1password.com/downloads/command-line/ or enter the path manually.")
        }
    }

    // MARK: - Keychain Section

    private var keychainSection: some View {
        Section("Keychain Storage") {
            LabeledContent("Password") {
                VStack(alignment: .leading) {
                HStack {
                    
                    SecureField("VPN password", text: $keychainPassword)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    if hasStoredPassword {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Password is stored in Keychain")
                    }
                        
                }
                    Text("Okta password")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                }
            }

            LabeledContent("TOTP Seed") {
                VStack(alignment: .leading) {
                    HStack {
                        SecureField("Base32 secret key", text: $keychainTOTPSeed)
                            .textFieldStyle(.roundedBorder).labelsHidden()
                        if hasStoredTOTPSeed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help("TOTP seed is stored in Keychain")
                        }
                    }
                    Text("Base32 secret key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

#Preview {CredentialSettingsView()}
