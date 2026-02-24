import ApplicationServices
import Foundation

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

    /// Check if the app is already connected by reading the Cisco button title.
    @MainActor
    static func checkConnectionStatus() -> Bool {
        let source = """
        tell application "System Events" to tell process "Cisco Secure Client"
            if not (exists (first window whose name is equal to "Cisco Secure Client")) then
                return false
            end if
            set client_window to first window whose name is equal to "Cisco Secure Client"
            set action_button to button 1 of client_window
            return title of action_button is equal to "Disconnect"
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return false }
        return result.booleanValue
    }

    /// Run the full VPN connection automation with the given credentials.
    @MainActor
    static func connect(password: String, otp: String) throws {
        let escapedPassword = escapeForAppleScript(password)
        let escapedOTP = escapeForAppleScript(otp)

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

            -- Wait for password window
            tell (a reference to (first window whose name starts with "Cisco Secure Client | " and size is equal to {469, 195}))
                repeat until it exists
                    delay 0.1
                end repeat
                set pwd_window to it
            end tell

            -- Enter password
            tell (a reference to (text field 2 of pwd_window))
                set value to "\(escapedPassword)"
                perform action "AXConfirm"
            end tell

            -- Wait for OTP window
            tell (a reference to (first window whose name starts with "Cisco Secure Client | " and size is equal to {452, 270}))
                repeat until it exists
                    delay 0.1
                end repeat
                set otp_window to it
            end tell

            -- Enter OTP
            tell (a reference to (text field 1 of otp_window))
                set value to "\(escapedOTP)"
                perform action "AXConfirm"
            end tell

            -- Wait for and dismiss banner
            tell (a reference to (first window whose name starts with "Cisco Secure Client - Banner"))
                repeat until it exists
                    delay 0.1
                end repeat
                set banner_window to it
            end tell

            tell button 1 of banner_window to click
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw AutomationError.scriptFailed("Failed to create AppleScript.")
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw AutomationError.scriptFailed(message)
        }
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
