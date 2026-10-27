import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [MouseDevice] = []
    @Published private(set) var activeDeviceID: String?
    @Published private(set) var issues: [ProviderIssue] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var settings: AppSettings
    @Published var settingsMessage: String?
    @Published var isFullscreenCovered = false

    let settingsStore: SettingsStore

    var onDevicesChanged: (() -> Void)?
    var onRefreshRequested: (() -> Void)?
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onQuitRequested: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> String?)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.settings
        self.activeDeviceID = settings.selectedDeviceID
    }

    var activeDevice: MouseDevice? {
        if let activeDeviceID, let match = devices.first(where: { $0.id == activeDeviceID }) {
            return match
        }
        return devices.first
    }

    var autoRefreshText: String {
        switch settings.refreshInterval {
        case 30: return "每 30 秒自动刷新"
        case 120: return "每 2 分钟自动刷新"
        case 300: return "每 5 分钟自动刷新"
        default: return "每分钟自动刷新"
        }
    }

    var hasAnyStaleDevice: Bool {
        devices.contains { $0.isStale }
    }

    func beginScan() {
        isScanning = true
    }

    func apply(_ outcome: ScanOutcome) {
        let previousDevices = devices
        let failedProviders = Set(outcome.issues.map(\.provider))
        let fresh = outcome.devices
        let retained = previousDevices
            .filter { failedProviders.contains($0.provider) }
            .filter { previous in !fresh.contains(where: { $0.provider == previous.provider }) }
            .map { device -> MouseDevice in
                var copy = device
                copy.isStale = true
                return copy
            }

        devices = (fresh + retained).sorted { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            if lhs.connection != rhs.connection {
                return lhs.connection == .receiver
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        issues = outcome.issues
        lastAttempt = outcome.timestamp
        if !fresh.isEmpty {
            lastUpdated = outcome.timestamp
        } else if lastUpdated == nil {
            lastUpdated = outcome.timestamp
        }

        if let selected = activeDeviceID,
           let match = devices.first(where: { $0.id == selected }) {
            activeDeviceID = match.id
        } else {
            activeDeviceID = devices.first?.id
        }

        isScanning = false
        onDevicesChanged?()
    }

    func recordFailure(_ message: String) {
        issues = [ProviderIssue(provider: .atk, code: "SCAN_FAILED", message: "读取电量失败", detail: message)]
        lastAttempt = Date()
        isScanning = false
        onDevicesChanged?()
    }

    func selectDevice(_ id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        activeDeviceID = id
        updateSettings(selectedDeviceID: id)
    }

    func adoptSystemLaunchAtLogin(_ enabled: Bool) {
        guard settings.launchAtLogin != enabled else { return }
        updateSettings(launchAtLogin: enabled, notifySettings: false)
    }

    func setRefreshInterval(_ interval: Int) {
        guard AppSettings.allowedIntervals.contains(interval) else { return }
        updateSettings(refreshInterval: interval)
    }

    func setLowBatteryAlerts(_ enabled: Bool) {
        updateSettings(lowBatteryAlerts: enabled)
    }

    func setHideWhenFullscreen(_ enabled: Bool) {
        updateSettings(hideWhenFullscreen: enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let onLaunchAtLoginChanged, let error = onLaunchAtLoginChanged(enabled) {
            settingsMessage = error
            return
        }
        updateSettings(launchAtLogin: enabled, notifySettings: false)
        settingsMessage = nil
    }

    func refresh() {
        onRefreshRequested?()
    }

    func quit() {
        onQuitRequested?()
    }

    func copyDiagnostics() {
        onCopyDiagnostics?()
    }

    func clearMessage() {
        settingsMessage = nil
    }

    private func updateSettings(
        refreshInterval: Int? = nil,
        lowBatteryAlerts: Bool? = nil,
        hideWhenFullscreen: Bool? = nil,
        launchAtLogin: Bool? = nil,
        selectedDeviceID: String? = nil,
        notifySettings: Bool = true
    ) {
        settingsStore.update { settings in
            if let refreshInterval { settings.refreshInterval = refreshInterval }
            if let lowBatteryAlerts { settings.lowBatteryAlerts = lowBatteryAlerts }
            if let hideWhenFullscreen { settings.hideWhenFullscreen = hideWhenFullscreen }
            if let launchAtLogin { settings.launchAtLogin = launchAtLogin }
            if let selectedDeviceID { settings.selectedDeviceID = selectedDeviceID }
        }
        settings = settingsStore.settings
        if notifySettings {
            onSettingsChanged?(settings)
        } else {
            onSettingsChanged?(settings)
        }
        onDevicesChanged?()
    }

    func diagnosticText() -> String {
        let deviceLines = devices.map { device in
            "- \(device.provider.rawValue) | \(device.name) | \(device.batteryText) | stale=\(device.isStale) | \(device.hardware)"
        }
        let issueLines = issues.map { "- \($0.provider.rawValue)/\($0.code): \($0.message) \($0.detail ?? "")" }
        return [
            "电量栏 原生版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Updated: \(lastUpdated?.description ?? "never")",
            "Attempted: \(lastAttempt?.description ?? "never")",
            "Devices:",
            deviceLines.isEmpty ? "- none" : deviceLines.joined(separator: "\n"),
            "Issues:",
            issueLines.isEmpty ? "- none" : issueLines.joined(separator: "\n"),
            "Settings: \(settings)",
        ].joined(separator: "\n")
    }
}
