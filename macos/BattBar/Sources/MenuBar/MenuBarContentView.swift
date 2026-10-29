import AppKit

final class MenuBarContentView: NSView {
    static let maxWidth: CGFloat = 198
    static let minWidth: CGFloat = 118
    private static let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let emptyFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)

    var onToggle: (() -> Void)?
    var onRightClick: (() -> Void)?

    private(set) var devices: [MouseDevice] = []
    private(set) var currentIndex = 0
    private var previousIndex: Int?
    private var transitionStarted: CFTimeInterval = 0
    private var transitionProgress: CGFloat = 1
    private var scrollOffset: CGFloat = 0
    private var pauseTicks = 0
    private var overflow: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    private let transitionDuration: CFTimeInterval = 0.28

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The whole item should be clickable, including the transparent area.
        return bounds.contains(point) ? self : nil
    }

    func update(devices newDevices: [MouseDevice], preserveIndex: Bool = true) {
        let previousID = devices.indices.contains(currentIndex) ? devices[currentIndex].id : nil
        devices = newDevices
        if !preserveIndex {
            currentIndex = 0
        } else if let previousID,
                  let newIndex = devices.firstIndex(where: { $0.id == previousID }) {
            currentIndex = newIndex
        } else {
            currentIndex = 0
        }
        if currentIndex >= devices.count { currentIndex = 0 }
        previousIndex = nil
        transitionProgress = 1
        resetMarquee()
    }

    var currentDevice: MouseDevice? {
        guard devices.indices.contains(currentIndex) else { return nil }
        return devices[currentIndex]
    }

    var isAnimating: Bool {
        transitionProgress < 1 || overflow > 0.5
    }

    func beginDeviceTransition() {
        guard devices.count > 1, transitionProgress >= 1 else { return }
        previousIndex = currentIndex
        currentIndex = (currentIndex + 1) % devices.count
        transitionStarted = CACurrentMediaTime()
        transitionProgress = 0
        resetMarquee()
        needsDisplay = true
    }

    func tick() {
        let now = CACurrentMediaTime()
        let delta = max(0.001, min(0.1, now - max(lastTick, now - 0.1)))
        lastTick = now

        if transitionProgress < 1 {
            let elapsed = now - transitionStarted
            transitionProgress = min(1, CGFloat(elapsed / transitionDuration))
            if transitionProgress >= 1 {
                previousIndex = nil
            }
        }

        if overflow > 0.5 {
            if pauseTicks > 0 {
                pauseTicks -= 1
            } else {
                scrollOffset += CGFloat(delta) * 24
                if scrollOffset > overflow + 18 {
                    scrollOffset = 0
                    pauseTicks = 26
                }
            }
        }
        needsDisplay = true
    }

    func prepareForDisplay() {
        lastTick = CACurrentMediaTime()
        updateOverflow()
        if isAnimating { needsDisplay = true }
    }

    private func resetMarquee() {
        scrollOffset = 0
        pauseTicks = 26
        lastTick = CACurrentMediaTime()
        updateOverflow()
    }

    private func updateOverflow() {
        guard let device = currentDevice else { overflow = 0; return }
        let nameWidth = Self.textWidth(device.name, font: Self.nameFont)
        // Keep the exact same measurement as the clip rect in draw(device:).
        let nameArea = max(0, bounds.width - 8 - Self.batteryWidth(for: device) - 10 - 7)
        overflow = max(0, nameWidth - nameArea + 1)
    }

    /// Width the status item should reserve. The battery is right-aligned and
    /// cannot scroll, so it is sized for the widest device in the list: the
    /// active device can be charging (a bolt wider) or read "100%" while the
    /// first one reads "9%".
    static func preferredWidth(for devices: [MouseDevice]) -> CGFloat {
        guard let device = devices.first else { return 126 }
        let nameWidth = min(textWidth(device.name, font: nameFont), 132)
        let battery = devices.map { batteryWidth(for: $0) }.max() ?? batteryWidth(for: device)
        let width = min(maxWidth, max(minWidth, 8 + nameWidth + 10 + battery + 8))
        return ceil(width)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        if devices.isEmpty {
            drawEmpty()
        } else {
            if transitionProgress < 1, let previousIndex, devices.indices.contains(previousIndex), let currentDevice {
                let inY = bounds.height * transitionProgress
                let outY = -bounds.height * (1 - transitionProgress)
                draw(device: devices[previousIndex], yOffset: inY, alpha: 1 - transitionProgress * 0.35)
                draw(device: currentDevice, yOffset: outY, alpha: 0.4 + transitionProgress * 0.6)
            } else if let currentDevice {
                draw(device: currentDevice, yOffset: 0, alpha: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEmpty() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.emptyFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = "未发现鼠标" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: 8, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    private func draw(device: MouseDevice, yOffset: CGFloat, alpha: CGFloat) {
        // A battery outline in the level colour: the fill inside shows the level,
        // the percentage sits on top of it, and charging only adds a bolt so the
        // colour keeps its meaning.
        let color = device.isStale || device.battery == nil
            ? NSColor.secondaryLabelColor
            : Self.levelColor(for: device)
        let body = NSRect(
            x: bounds.width - 8 - Self.batteryWidth(for: device),
            y: (bounds.height - Battery.height) / 2 + yOffset,
            width: Self.batteryWidth(for: device) - Battery.capGap - Battery.capWidth,
            height: Battery.height
        )
        let outline = NSBezierPath(
            roundedRect: body,
            xRadius: Battery.cornerRadius,
            yRadius: Battery.cornerRadius
        )
        outline.lineWidth = 1
        color.withAlphaComponent(alpha * 0.85).setStroke()
        outline.stroke()

        // The fill shows the level; it stays translucent because the percentage
        // is drawn over it and must stay readable at low levels.
        let fraction = min(1, max(0, CGFloat(device.battery ?? 0) / 100))
        let fillWidth = max(0, (body.width - 3) * fraction)
        if fillWidth > 0.5 {
            let fill = NSBezierPath(
                roundedRect: NSRect(x: body.minX + 1.5, y: body.minY + 1.5,
                                    width: fillWidth, height: body.height - 3),
                xRadius: 1.5,
                yRadius: 1.5
            )
            color.withAlphaComponent(alpha * Battery.fillAlpha).setFill()
            fill.fill()
        }

        let cap = NSBezierPath(
            roundedRect: NSRect(x: body.maxX + Battery.capGap, y: body.midY - Battery.capHeight / 2,
                                width: Battery.capWidth, height: Battery.capHeight),
            xRadius: 1,
            yRadius: 1
        )
        color.withAlphaComponent(alpha * 0.85).setFill()
        cap.fill()

        // The number sits on the fill, which is translucent, so it has to follow
        // the menu bar: white on the dark bar, label colour on the light one.
        let ink = NSColor.labelColor.withAlphaComponent(alpha)
        var textX = body.minX + Battery.padding
        if device.charging == true {
            drawBolt(
                in: NSRect(x: textX, y: body.midY - Battery.boltHeight / 2,
                           width: Battery.boltWidth, height: Battery.boltHeight),
                color: ink
            )
            textX += Battery.boltWidth + Battery.boltGap
        }

        let batteryText = device.menuBatteryText as NSString
        let batterySize = batteryText.size(withAttributes: [.font: Battery.font])
        batteryText.draw(
            at: NSPoint(x: textX, y: body.minY + (Battery.height - batterySize.height) / 2),
            withAttributes: [
                .font: Battery.font,
                .foregroundColor: ink,
            ]
        )

        let available = max(0, body.minX - 10 - 7)
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.nameFont,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
        ]
        let name = device.name as NSString
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 7, y: 0, width: available, height: bounds.height)).addClip()
        let nameSize = name.size(withAttributes: nameAttributes)
        let baseY = (bounds.height - nameSize.height) / 2 + yOffset
        if overflow <= 0.5 {
            name.draw(at: NSPoint(x: 8, y: baseY), withAttributes: nameAttributes)
        } else {
            let width = nameSize.width
            let gap: CGFloat = 26
            let firstX = 8 - scrollOffset
            name.draw(at: NSPoint(x: firstX, y: baseY), withAttributes: nameAttributes)
            name.draw(at: NSPoint(x: firstX + width + gap, y: baseY), withAttributes: nameAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Battery geometry. `batteryWidth(for:)` measures with `Battery.font`, so
    /// the reserved width and the drawn width cannot drift apart.
    private enum Battery {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        static let height: CGFloat = 15
        static let padding: CGFloat = 6
        static let boltWidth: CGFloat = 7
        static let boltHeight: CGFloat = 9
        static let boltGap: CGFloat = 2
        static let cornerRadius: CGFloat = 3
        /// Nub on the right end, the part that makes it read as a battery.
        static let capWidth: CGFloat = 2.5
        static let capGap: CGFloat = 1
        static let capHeight: CGFloat = 5
        /// The fill stays translucent: the percentage is drawn on top of it.
        static let fillAlpha: CGFloat = 0.45
    }

    /// Width of the battery for `device`, including the bolt when charging.
    static func batteryWidth(for device: MouseDevice) -> CGFloat {
        let size = (device.menuBatteryText as NSString).size(withAttributes: [.font: Battery.font])
        let bolt = device.charging == true ? Battery.boltWidth + Battery.boltGap : 0
        return ceil(size.width + bolt + Battery.padding * 2 + Battery.capGap + Battery.capWidth)
    }

    private static func levelColor(for device: MouseDevice) -> NSColor {
        guard let battery = device.battery else { return .tertiaryLabelColor }
        if battery <= 20 { return .systemRed }
        if battery <= 40 { return .systemOrange }
        return .systemGreen
    }

    /// Draws the charging bolt in `color`, matching the percentage next to it.
    private func drawBolt(in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: Battery.boltHeight, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "充电中")?
            .withSymbolConfiguration(configuration) else {
            return
        }
        bolt.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
