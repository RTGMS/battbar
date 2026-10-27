import Foundation

enum DeviceProviderKind: String, Codable, CaseIterable {
    case atk
    case razer
    case bluetooth

    var priority: Int {
        switch self {
        case .atk: return 0
        case .razer: return 1
        case .bluetooth: return 2
        }
    }

    var displayName: String {
        switch self {
        case .atk: return "ATK HID"
        case .razer: return "Razer HID"
        case .bluetooth: return "系统蓝牙"
        }
    }
}

enum DeviceConnection: String, Codable {
    case receiver
    case bluetooth

    var label: String {
        switch self {
        case .receiver: return "2.4 GHz"
        case .bluetooth: return "蓝牙"
        }
    }
}

struct MouseDevice: Identifiable, Equatable {
    let id: String
    let provider: DeviceProviderKind
    var name: String
    var subtitle: String
    var connection: DeviceConnection
    var source: String
    var battery: Int?
    var charging: Bool?
    var lastSeen: Date
    var isStale: Bool
    var hardware: [String: String]

    var connectionLabel: String { connection.label }

    var batteryText: String {
        guard let battery else { return "--" }
        return "\(battery)%"
    }

    var menuBatteryText: String {
        guard let battery else { return "--" }
        return isStale ? "~\(battery)%" : "\(battery)%"
    }

    var isLow: Bool {
        guard let battery else { return false }
        return battery <= 20
    }

    var isCritical: Bool {
        guard let battery else { return false }
        return battery <= 10
    }

    var accessibilityDescription: String {
        "\(name)，\(isStale ? "上次读数 " : "")\(batteryText)"
    }
}

struct ProviderIssue: Identifiable, Equatable {
    var id: String { "\(provider.rawValue)-\(code)" }
    let provider: DeviceProviderKind
    let code: String
    let message: String
    let detail: String?
}

struct ProviderOutcome {
    var devices: [MouseDevice] = []
    var issues: [ProviderIssue] = []
}

struct ScanOutcome {
    var devices: [MouseDevice] = []
    var issues: [ProviderIssue] = []
    var timestamp: Date = Date()
}

