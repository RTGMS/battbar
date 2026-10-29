import Foundation

struct AppSettings: Codable, Equatable {
    var refreshInterval: Int = 60
    var lowBatteryAlerts: Bool = true
    var hideWhenFullscreen: Bool = true
    var launchAtLogin: Bool = false
    var selectedDeviceID: String?

    static let allowedIntervals = [30, 60, 120, 300]

    mutating func sanitize() {
        if !Self.allowedIntervals.contains(refreshInterval) { refreshInterval = 60 }
        if let selectedDeviceID, selectedDeviceID.count > 512 { self.selectedDeviceID = nil }
    }
}

final class SettingsStore {
    private let key = "battbar.settings.v2"
    private let defaults: UserDefaults
    private(set) var settings: AppSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        settings.sanitize()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings.sanitize()
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
