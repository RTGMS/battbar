import AppKit

final class MenuBarContentView: NSView {
    static let maxWidth: CGFloat = 198
    static let minWidth: CGFloat = 118
    private static let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let batteryFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
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
        let batteryWidth = Self.textWidth(device.menuBatteryText, font: Self.batteryFont)
        // Keep the exact same measurement as the clip rect in draw(device:).
        let nameArea = max(0, bounds.width - 8 - 27 - batteryWidth)
        overflow = max(0, nameWidth - nameArea + 1)
    }

    static func preferredWidth(for devices: [MouseDevice]) -> CGFloat {
        guard let device = devices.first else { return 126 }
        let nameWidth = min(textWidth(device.name, font: nameFont), 132)
        let batteryWidth = textWidth(device.menuBatteryText, font: batteryFont)
        let width = min(maxWidth, max(minWidth, 8 + nameWidth + 10 + 5 + 12 + batteryWidth + 8))
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
        let batteryText = device.menuBatteryText as NSString
        let batteryAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.batteryFont,
            .foregroundColor: device.isStale ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let batterySize = batteryText.size(withAttributes: batteryAttributes)
        let batteryX = bounds.width - 8 - batterySize.width

        drawBatteryGlyph(
            x: batteryX - 17,
            y: (bounds.height - 6) / 2 + yOffset,
            fraction: CGFloat(device.battery ?? 0) / 100,
            color: dotColor(for: device),
            alpha: alpha,
            stale: device.isStale
        )

        batteryText.draw(
            at: NSPoint(x: batteryX, y: (bounds.height - batterySize.height) / 2 + yOffset),
            withAttributes: batteryAttributes.merging([.foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)]) { _, new in new }
        )

        let available = max(0, batteryX - 27)
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

    private func drawBatteryGlyph(
        x: CGFloat,
        y: CGFloat,
        fraction: CGFloat,
        color: NSColor,
        alpha: CGFloat,
        stale: Bool
    ) {
        let body = NSRect(x: x, y: y, width: 10, height: 6)
        let outline = NSBezierPath(roundedRect: body, xRadius: 1.4, yRadius: 1.4)
        outline.lineWidth = 1
        // A stale reading still has a level worth showing: keep the same shape,
        // just muted, so an idle mouse does not read as an empty battery.
        color.withAlphaComponent(alpha * (stale ? 0.85 : 0.55)).setStroke()
        outline.stroke()

        let innerWidth = max(0, (body.width - 3) * min(1, max(0, fraction)))
        if innerWidth > 0 {
            let fill = NSBezierPath(
                roundedRect: NSRect(x: body.minX + 1.5, y: body.minY + 1.5, width: innerWidth, height: body.height - 3),
                xRadius: 0.6,
                yRadius: 0.6
            )
            color.withAlphaComponent(alpha * (stale ? 0.55 : 0.95)).setFill()
            fill.fill()
        }

        let cap = NSBezierPath(
            roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 1.5, width: 1.5, height: 3),
            xRadius: 0.7,
            yRadius: 0.7
        )
        color.withAlphaComponent(alpha * (stale ? 0.85 : 0.55)).setFill()
        cap.fill()
    }

    private func dotColor(for device: MouseDevice) -> NSColor {
        guard let battery = device.battery else { return .tertiaryLabelColor }
        if device.isStale { return .secondaryLabelColor }
        if battery <= 20 { return .systemRed }
        if battery <= 40 { return .systemOrange }
        return .systemGreen
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
