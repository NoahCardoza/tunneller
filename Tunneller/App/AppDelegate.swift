import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    let vpnManager = VPNManager()
    private var cancellable: AnyCancellable?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: vpnManager.state.iconName,
                accessibilityDescription: "VPN Status"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Update status bar icon whenever VPN state changes
        cancellable = vpnManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: state.iconName,
                    accessibilityDescription: "VPN Status"
                )
            }

        // Auto-discover op binary path on first launch
        let settings = AppSettings.shared
        if !settings.hasRunOpDiscovery {
            if let path = OnePasswordProvider.discoverOpBinaryPath() {
                settings.opBinaryPath = path
            }
            settings.hasRunOpDiscovery = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            vpnManager.refreshStatus()
            rebuildMenu(menu)
        }
    }

    // MARK: - Menu Construction

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status label
        let statusItem = NSMenuItem(
            title: vpnManager.state.statusLabel,
            action: nil,
            keyEquivalent: ""
        )
        statusItem.image = NSImage(
            systemSymbolName: vpnManager.state.iconName,
            accessibilityDescription: nil
        )
        menu.addItem(statusItem)
        menu.addItem(.separator())

        // Connect / status
        switch vpnManager.state {
        case .disconnected, .error:
            let connectItem = NSMenuItem(
                title: "Connect",
                action: #selector(connectVPN),
                keyEquivalent: "c"
            )
            connectItem.target = self
            menu.addItem(connectItem)
        case .connecting:
            let item = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .connected:
            let item = NSMenuItem(title: "VPN is active", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func connectVPN() {
        if let error = vpnManager.credentialConfigurationError() {
            let alert = NSAlert()
            alert.messageText = "Credentials Not Configured"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")

            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
            return
        }

        Task {
            await vpnManager.connect()
        }
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
