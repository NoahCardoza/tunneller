import Foundation

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var statusLabel: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let message): "Error: \(message)"
        }
    }

    var iconName: String {
        switch self {
        case .disconnected, .error: "shield.slash"
        case .connecting: "shield.badge.clock"  // macOS 14+ SF Symbol
        case .connected: "shield.checkmark"
        }
    }
}
