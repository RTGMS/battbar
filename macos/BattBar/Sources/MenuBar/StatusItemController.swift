import AppKit

final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    let contentView: MenuBarContentView
    var onTogglePanel: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var cycleTimer: Timer?
    private var animationTimer: Timer?
    private var paused = false
    private var hiddenForFullscreen = false

    override init() {
        let initialWidth = MenuBarContentView.minWidth
        statusItem = NSStatusBar.system.statusItem(withLength: initialWidth)
        contentView = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 22))
        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.addSubview(contentView)
            contentView.frame = button.bounds
            contentView.autoresizingMask = [.width, .height]
            button.toolTip = "电量栏"
            button.setAccessibilityLabel("电量栏")
        }
        contentView.onToggle = { [weak self] in
            self?.onTogglePanel?()
        }
        contentView.onRightClick = { [weak self] in
            self?.showContextMenu()
        }
        statusItem.length = initialWidth
    }

    deinit {
        cycleTimer?.invalidate()
        animationTimer?.invalidate()
    }

    func update(devices: [MouseDevice], preserveIndex: Bool = true) {
        let width = MenuBarContentView.preferredWidth(for: devices)
        if abs(statusItem.length - width) > 0.5 {
            statusItem.length = width
            contentView.frame = NSRect(x: 0, y: 0, width: width, height: contentView.frame.height)
        }
        contentView.update(devices: devices, preserveIndex: preserveIndex)
        updateTooltip(devices: devices)
        updateAccessibility(devices: devices)
        restartCycleTimerIfNeeded()
        updateAnimationTimer()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            stopTimers()
        } else {
            restartCycleTimerIfNeeded()
            updateAnimationTimer()
        }
    }

    func setHiddenForFullscreen(_ hidden: Bool) {
        hiddenForFullscreen = hidden
        statusItem.isVisible = !hidden
        if hidden {
            stopTimers()
        } else {
            restartCycleTimerIfNeeded()
            contentView.prepareForDisplay()
            updateAnimationTimer()
        }
    }

    var isHiddenForFullscreen: Bool { hiddenForFullscreen }

    func flashHighlight() {
        guard let button = statusItem.button else { return }
        button.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            button.highlight(false)
        }
    }

    private func updateTooltip(devices: [MouseDevice]) {
        let lines = devices.map { device in
            let charging = device.charging == true ? "，充电中" : ""
            return "\(device.name)：\(device.isStale ? "上次读数 " : "")\(device.batteryText)\(charging)"
        }
        statusItem.button?.toolTip = lines.isEmpty ? "电量栏 · 未发现鼠标" : lines.joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(
            devices.isEmpty ? "电量栏，未发现鼠标" : devices.map(\.accessibilityDescription).joined(separator: "；")
        )
    }

    private func updateAccessibility(devices: [MouseDevice]) {
        // accessibilityLabel is updated together with the tooltip.
    }

    private func restartCycleTimerIfNeeded() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        guard !paused, !hiddenForFullscreen, contentView.devices.count > 1 else { return }
        let timer = Timer(timeInterval: 5.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.contentView.beginDeviceTransition()
            self.updateAnimationTimer()
        }
        timer.tolerance = 0.8
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }

    private func updateAnimationTimer() {
        let shouldAnimate = contentView.isAnimating && !paused && !hiddenForFullscreen
        if shouldAnimate {
            guard animationTimer == nil else { return }
            contentView.prepareForDisplay()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.contentView.tick()
                if !self.contentView.isAnimating || self.paused || self.hiddenForFullscreen {
                    self.animationTimer?.invalidate()
                    self.animationTimer = nil
                }
            }
            timer.tolerance = 0.015
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !contentView.isAnimating {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func stopTimers() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func showContextMenu() {
        guard let menu = menuProvider?() else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
