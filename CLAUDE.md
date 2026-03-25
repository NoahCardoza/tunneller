# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Tunneller is a native macOS menu bar app (SwiftUI, macOS 14.0+) that automates Cisco Secure Client VPN connections. It fetches credentials from either the macOS Keychain (biometric-protected) or 1Password CLI, generates TOTP codes, and drives the Cisco UI via AppleScript.

## Build & Test Commands

```bash
# Build (clean + build)
./build.sh

# Build and launch
./build.sh --run

# Run tests
xcodebuild -project Tunneller.xcodeproj -scheme Tunneller test \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Xcode project: `Tunneller.xcodeproj`, scheme: `Tunneller`, bundle ID: `com.quicken.tunneller`.

## Architecture

```
Tunneller/
  App/          – Entry point (TunnellerApp) and AppDelegate (menu bar, window lifecycle)
  Models/       – AppSettings (@AppStorage), CredentialSource enum, VPNState enum
  Services/
    Credentials/ – CredentialProvider protocol with KeychainProvider and OnePasswordProvider
    TOTP/        – RFC 6238 TOTP generator (HMAC-SHA1, base32, no external deps)
    VPN/         – VPNManager (orchestrator) and VPNAutomation (AppleScript automation)
  Views/Settings/ – SettingsView (TabView), GeneralSettingsView, CredentialSettingsView
```

**Key flow:** AppDelegate menu action → VPNManager.connect() → selected CredentialProvider fetches password + TOTP seed → TOTPGenerator produces code → VPNAutomation drives Cisco Secure Client via AppleScript.

**Patterns:** Protocol-driven credential providers, `@Published` state on VPNManager, `AppSettings.shared` singleton for UserDefaults, async/await concurrency.

## Important Details

- AppleScript in `VPNAutomation` interacts with Cisco Secure Client windows — requires Accessibility permission. Passwords and OTP codes are injected into form fields with proper escaping.
- KeychainProvider stores password + TOTP seed in a single biometric-protected keychain item. There is migration logic for legacy separate-item format.
- OnePasswordProvider shells out to `op read` with configurable binary path and item references.
- The app uses `ServiceManagement` for launch-at-login, not a login item helper.
- All crypto uses Apple's `CryptoKit` and `Security` frameworks — no third-party dependencies.
