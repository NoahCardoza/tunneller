import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "com.tunneller", category: "VPNAutomation")

enum VPNAutomation {
    enum AutomationError: LocalizedError {
        case scriptFailed(String)
        case accessibilityNotGranted

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                "AppleScript error: \(message)"
            case .accessibilityNotGranted:
                "Accessibility permission is required. Grant access in System Settings → Privacy & Security → Accessibility."
            }
        }
    }

    /// Check if the VPN is connected by querying the Cisco Secure Client CLI.
    static func checkConnectionStatus() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/cisco/secureclient/bin/vpn")
        process.arguments = ["state"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.info("checkConnectionStatus: failed to run vpn CLI — \(error.localizedDescription)")
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let connected = output.localizedCaseInsensitiveContains("state: Connected")
        logger.info("checkConnectionStatus: result = \(connected)")
        return connected
    }

    /// Run the full VPN connection automation with the given credentials.
    static func connect(password: String, otp: String, mfaMethodNumber: String? = nil) async throws {
        let escapedPassword = escapeForAppleScript(password)
        let escapedOTP = escapeForAppleScript(otp)
        let mfaMethodSelectionScript: String

        if let mfaMethodNumber {
            let escapedMFAMethodNumber = escapeForAppleScript(mfaMethodNumber)
            mfaMethodSelectionScript = """
            -- Wait for the auth method selection window. Both this prompt and the OTP prompt
            -- have a Continue button, so require the method prompt's unique Answer label.
            set auth_window to missing value
            repeat 100 times
                delay 0.1
                repeat with w in windows
                    try
                        if (exists button "Continue" of w) and (exists static text "Answer:" of w) then
                            set auth_window to w
                            exit repeat
                        end if
                    end try
                end repeat
                if auth_window is not missing value then exit repeat
            end repeat

            if auth_window is missing value then
                error "Could not find the MFA method selection prompt. Clear the MFA method setting if Cisco no longer shows it."
            end if

            -- Select the configured authentication method and continue.
            tell (text field 1 of auth_window)
                set value to "\(escapedMFAMethodNumber)"
            end tell
            click button "Continue" of auth_window
            """
        } else {
            mfaMethodSelectionScript = ""
        }

        let source = """
        tell application "Cisco Secure Client" to activate
        
        tell application "System Events"
            tell process "Cisco Secure Client"
                click menu item "Show Cisco Secure Client Window" of menu "Cisco Secure Client" of menu bar 1
            end tell
        end tell

        tell application "System Events" to tell process "Cisco Secure Client"
            -- Dismiss any existing sheet
            tell (a reference to (sheet 1 of window "Cisco Secure Client"))
                if it exists then
                    tell button "OK" of it to click
                end if
            end tell

            -- Close any extra windows (e.g. details panels)
            repeat with win in (windows whose name contains " | ")
                perform action "AXRaise" of win
                key code 53
            end repeat

            set client_window to first window whose name is equal to "Cisco Secure Client"
            set action_button to button 1 of client_window

            -- Already connected? Just hide and return.
            if title of action_button is equal to "Disconnect" then
                set visible to false
                return
            end if

            click action_button

            -- Wait up to 20 seconds for password window
            set pwd_window to missing value
            repeat 200 times
                try
                    set pwd_window to first window whose name starts with "Cisco Secure Client | " and size is equal to {469, 195}
                end try
                if pwd_window is not missing value then exit repeat
                delay 0.1
            end repeat
            if pwd_window is missing value then error "Timed out waiting for the password prompt."

            -- Enter password
            tell (a reference to (text field 2 of pwd_window))
                set value to "\(escapedPassword)"
                perform action "AXConfirm"
            end tell

            \(mfaMethodSelectionScript)

            -- Wait up to 20 seconds for OTP window
            set otp_window to missing value
            repeat 200 times
                try
                    set otp_window to first window whose name starts with "Cisco Secure Client | " and size is equal to {452, 270}
                end try
                if otp_window is not missing value then exit repeat
                delay 0.1
            end repeat
            if otp_window is missing value then error "Timed out waiting for the OTP prompt."

            -- Enter OTP
            tell (a reference to (text field 1 of otp_window))
                set value to "\(escapedOTP)"
                perform action "AXConfirm"
            end tell

            -- Wait up to 20 seconds for and dismiss banner
            set banner_window to missing value
            repeat 200 times
                try
                    set banner_window to first window whose name starts with "Cisco Secure Client - Banner"
                end try
                if banner_window is not missing value then exit repeat
                delay 0.1
            end repeat
            if banner_window is missing value then error "Timed out waiting for the connection banner."

            tell button 1 of banner_window to click
        end tell
        """

        try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else {
                throw AutomationError.scriptFailed("Failed to create AppleScript.")
            }

            var error: NSDictionary?
            script.executeAndReturnError(&error)

            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                throw AutomationError.scriptFailed(message)
            }
        }.value
    }

    /// Escape a string for embedding inside AppleScript double-quoted strings.
    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Check if Accessibility permission is granted.
    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user to grant Accessibility permission.
    static func promptAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
