import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private lazy var model = AppModel(settingsStore: settingsStore)
    private lazy var scanner = Scanner(model: model)
    private lazy var notifications = NotificationService()
    private let launchAtLogin = LaunchAtLoginService()

    private var statusController: StatusItemController!
    private var panelController: PanelController!
    private var fullscreenMonitor: FullScreenMonitor!
    private var refreshTimer: Timer?
    private var retryTimer: Timer?
    private var retrying = false
    private var screenLocked = false
    private var fullscreenCovered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupModelCallbacks()
        setupFullscreen()
        setupWorkspaceObservers()
        syncLaunchAtLoginState()
        scheduleRefreshTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scanner.scan(forceBluetooth: true)
        }
        if CommandLine.arguments.contains("--self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.runSelfTest()
            }
        }
    }

    private func runSelfTest() {
        print("SELF-TEST devices=\(model.devices.count) active=\(model.activeDevice?.name ?? "nil") battery=\(model.activeDevice?.batteryText ?? "nil")")
        print("SELF-TEST issues=\(model.issues.map(\.code))")
        print("SELF-TEST statusVisible=\(statusController.statusItem.isVisible) length=\(statusController.statusItem.length)")
        panelController.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            print("SELF-TEST panelShown=\(self.panelController.isShown)")
            self.panelController.close()
            self.statusController.update(devices: self.model.devices, preserveIndex: false)
            let hold = Double(ProcessInfo.processInfo.environment["BATTBAR_SELFTEST_HOLD"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 + hold) {
                print("SELF-TEST panelShownAfterClose=\(self.panelController.isShown)")
                let ok = self.statusController.statusItem.isVisible && self.panelController.isShown == false
                print(ok ? "SELF-TEST PASS" : "SELF-TEST FAIL")
                exit(ok ? 0 : 1)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        retryTimer?.invalidate()
        fullscreenMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusController = StatusItemController()
        statusController.onTogglePanel = { [weak self] in
            self?.statusController.flashHighlight()
            self?.panelController.toggle()
        }
        statusController.menuProvider = { [weak self] in
            self?.buildStatusMenu() ?? NSMenu()
        }
        statusController.update(devices: [], preserveIndex: false)
    }

    private func setupPanel() {
        let actions = PanelActions(
            refresh: { [weak self] in self?.refresh() },
            selectDevice: { [weak self] id in self?.model.selectDevice(id) },
            setRefreshInterval: { [weak self] interval in
                self?.model.setRefreshInterval(interval)
                self?.scheduleRefreshTimer()
            },
            setLowBatteryAlerts: { [weak self] enabled in
                self?.model.setLowBatteryAlerts(enabled)
                if enabled { self?.notifications.requestAuthorizationIfNeeded() }
            },
            setHideWhenFullscreen: { [weak self] enabled in
                self?.model.setHideWhenFullscreen(enabled)
                self?.applyFullscreenState(self?.fullscreenCovered ?? false)
            },
            setLaunchAtLogin: { [weak self] enabled in
                self?.model.setLaunchAtLogin(enabled)
            },
            copyDiagnostics: { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.model.diagnosticText(), forType: .string)
            },
            testNotification: { [weak self] in
                guard let self else { return }
                self.notifications.sendTest { granted in
                    self.model.settingsMessage = granted ? "测试通知已发送" : "通知未获授权，请在系统设置中允许电量栏发送通知。"
                }
            },
            quit: { NSApp.terminate(nil) }
        )

        panelController = PanelController(
            model: model,
            actions: actions,
            anchorProvider: { [weak self] in self?.statusController.statusItem.button }
        )
        panelController.onVisibilityChanged = { [weak self] visible in
            self?.statusController.setPaused(visible)
        }
        panelController.onOpen = { [weak self] in
            guard let self else { return }
            // Opening the panel is a user asking for the current level, so a
            // stale reading always re-reads; the recency guard only exists to
            // avoid a second scan right after a scheduled one.
            let stale = self.model.devices.contains { $0.isStale }
            if stale
                || self.model.lastAttempt == nil
                || Date().timeIntervalSince(self.model.lastAttempt ?? .distantPast) > 15 {
                self.refresh()
            }
        }
    }

    private func setupModelCallbacks() {
        model.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.statusController.update(devices: self.model.devices)
        }
        model.onRefreshRequested = { [weak self] in self?.refresh() }
        model.onQuitRequested = { NSApp.terminate(nil) }
        model.onCopyDiagnostics = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.model.diagnosticText(), forType: .string)
        }
        model.onLaunchAtLoginChanged = { [weak self] enabled in
            guard let self else { return "启动项不可用" }
            do {
                try self.launchAtLogin.setEnabled(enabled)
                return nil
            } catch {
                return "无法更新登录项：\(error.localizedDescription)"
            }
        }

        scanner.onScanCompleted = { [weak self] outcome in
            guard let self else { return }
            self.notifications.evaluate(outcome.devices, enabled: self.model.settings.lowBatteryAlerts)
            self.scheduleRetryIfNeeded()
        }
    }

    private var hasStaleDevice: Bool {
        model.devices.contains { $0.isStale }
    }

    /// One extra scan after a dropped read. The budget and the delay are the
    /// core's (`core/battbar-core/src/retry.rs`); this only owns the timer.
    private func scheduleRetryIfNeeded() {
        let delay = CoreBridge.retryDelayMilliseconds(
            hasStaleDevice: hasStaleDevice,
            alreadyRetried: retrying
        )
        retrying = false
        guard let delay else { return }
        let timer = Timer(timeInterval: TimeInterval(delay) / 1000, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retrying = true
            self.refresh()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func setupFullscreen() {
        fullscreenMonitor = FullScreenMonitor()
        fullscreenMonitor.onChange = { [weak self] fullscreen in
            guard let self else { return }
            self.fullscreenCovered = fullscreen
            self.applyFullscreenState(fullscreen)
        }
        fullscreenMonitor.start()
    }

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    // MARK: - Behavior

    private func syncLaunchAtLoginState() {
        model.adoptSystemLaunchAtLogin(launchAtLogin.isEnabled)
    }

    private func applyFullscreenState(_ fullscreen: Bool) {
        let shouldHide = fullscreen && model.settings.hideWhenFullscreen
        model.isFullscreenCovered = shouldHide
        if shouldHide {
            panelController.close()
            statusController.setHiddenForFullscreen(true)
            pauseForEnvironment()
        } else {
            statusController.setHiddenForFullscreen(false)
            resumeFromEnvironment()
        }
    }

    private func pauseForEnvironment() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        retrying = false
    }

    private func resumeFromEnvironment() {
        guard !screenLocked else { return }
        scheduleRefreshTimer()
        refresh()
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !screenLocked else { return }
        if fullscreenCovered && model.settings.hideWhenFullscreen { return }
        let interval = TimeInterval(model.settings.refreshInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = max(1, interval * 0.12)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        retryTimer?.invalidate()
        retryTimer = nil
        scanner.scan(forceBluetooth: false)
    }

    @objc private func screensDidSleep() {
        pauseForEnvironment()
        statusController.setPaused(true)
    }

    @objc private func screensDidWake() {
        statusController.setPaused(false)
        resumeFromEnvironment()
    }

    @objc private func screenDidLock() {
        screenLocked = true
        pauseForEnvironment()
    }

    @objc private func screenDidUnlock() {
        screenLocked = false
        if fullscreenCovered && model.settings.hideWhenFullscreen { return }
        scheduleRefreshTimer()
        refresh()
    }

    // MARK: - Menu

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        if let active = model.activeDevice {
            let info = NSMenuItem(title: "\(active.name) · \(active.batteryText)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "刷新电量", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let show = NSMenuItem(title: "显示面板", action: #selector(menuShowPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let alerts = NSMenuItem(title: "低电量提醒", action: #selector(menuToggleAlerts), keyEquivalent: "")
        alerts.target = self
        alerts.state = model.settings.lowBatteryAlerts ? .on : .off
        menu.addItem(alerts)

        let fullscreen = NSMenuItem(title: "全屏应用时隐藏", action: #selector(menuToggleFullscreen), keyEquivalent: "")
        fullscreen.target = self
        fullscreen.state = model.settings.hideWhenFullscreen ? .on : .off
        menu.addItem(fullscreen)

        if model.devices.count > 1 {
            menu.addItem(.separator())
            let devicesItem = NSMenuItem(title: "显示的设备", action: nil, keyEquivalent: "")
            devicesItem.isEnabled = false
            menu.addItem(devicesItem)
            for device in model.devices {
                let item = NSMenuItem(title: device.name, action: #selector(menuSelectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = model.activeDevice?.id == device.id ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出电量栏", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func menuRefresh() { refresh() }
    @objc private func menuShowPanel() {
        if !statusController.isHiddenForFullscreen {
            panelController.show()
        }
    }
    @objc private func menuToggleAlerts() {
        model.setLowBatteryAlerts(!model.settings.lowBatteryAlerts)
        if model.settings.lowBatteryAlerts { notifications.requestAuthorizationIfNeeded() }
    }
    @objc private func menuToggleFullscreen() {
        model.setHideWhenFullscreen(!model.settings.hideWhenFullscreen)
        applyFullscreenState(fullscreenCovered)
    }
    @objc private func menuSelectDevice(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.selectDevice(id) }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
