import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try renderMenu(to: directory.appendingPathComponent("native-menubar.png"))
            try renderPanel(to: directory.appendingPathComponent("native-panel.png"))
            print("已生成预览：\(directory.path)")
            return 0
        } catch {
            fputs("预览生成失败：\(error)\n", stderr)
            return 1
        }
    }

    private static func previewDevices() -> [MouseDevice] {
        let now = Date()
        return [
            MouseDevice(
                id: "preview-atk",
                provider: .atk,
                name: "ATK 无线鼠标",
                subtitle: "ATK Mouse 1K Dongle",
                connection: .receiver,
                source: "ATK HID",
                battery: 67,
                charging: false,
                lastSeen: now,
                isStale: false,
                hardware: ["vid": "0x373B", "pid": "0x101A"]
            ),
            MouseDevice(
                id: "preview-razer",
                provider: .razer,
                name: "Razer Viper V3 Pro",
                subtitle: "Razer HyperPolling Wireless Dongle",
                connection: .receiver,
                source: "Razer HID",
                battery: 23,
                charging: false,
                lastSeen: now,
                isStale: false,
                hardware: ["vid": "0x1532", "pid": "0x00C1"]
            ),
            MouseDevice(
                id: "preview-bt",
                provider: .bluetooth,
                name: "MX Master 3S",
                subtitle: "蓝牙",
                connection: .bluetooth,
                source: "macOS 蓝牙",
                battery: 100,
                charging: false,
                lastSeen: now,
                isStale: false,
                hardware: [:]
            ),
        ]
    }

    private static func renderMenu(to url: URL) throws {
        let devices = previewDevices()
        let normalWidth = MenuBarContentView.preferredWidth(for: [devices[0]])
        let longWidth = MenuBarContentView.maxWidth
        // The bolt makes the battery wider, so its row needs its own measurement.
        let chargingDevice = MouseDevice(
            id: "preview-charging",
            provider: .atk,
            name: "ATK 无线鼠标",
            subtitle: "ATK Mouse 1K Dongle",
            connection: .receiver,
            source: "ATK HID",
            battery: 88,
            charging: true,
            lastSeen: Date(),
            isStale: false,
            hardware: [:]
        )
        let chargingWidth = MenuBarContentView.preferredWidth(for: [chargingDevice])
        let rows: [(String, CGFloat, [MouseDevice])] = [
            ("ATK 无线鼠标", normalWidth, [devices[0]]),
            ("Razer Viper V3 Pro", longWidth, [devices[1]]),
            ("充电中", chargingWidth, [chargingDevice]),
            ("超长设备名称 · 左右滚动演示", MenuBarContentView.maxWidth, [
                MouseDevice(
                    id: "preview-long",
                    provider: .atk,
                    name: "ATK 超长名称无线鼠标 Pro Max 8K",
                    subtitle: "",
                    connection: .receiver,
                    source: "ATK HID",
                    battery: 9,
                    charging: false,
                    lastSeen: Date(),
                    isStale: false,
                    hardware: [:]
                )
            ]),
        ]

        let padding: CGFloat = 12
        let rowHeight: CGFloat = 26
        let width: CGFloat = 230
        let height: CGFloat = padding * 2 + rowHeight * CGFloat(rows.count)
        let scale: CGFloat = 6
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw RenderError.context
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for (index, row) in rows.enumerated() {
            let y = height - padding - rowHeight * CGFloat(index + 1)
            let itemRect = NSRect(x: 18, y: y, width: row.1, height: 22)
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: itemRect.insetBy(dx: -2, dy: 0), xRadius: 6, yRadius: 6).fill()
            let view = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: row.1, height: 22))
            view.update(devices: row.2, preserveIndex: false)
            view.prepareForDisplay()
            context.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: itemRect.minX, yBy: itemRect.minY)
            transform.concat()
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                view.draw(view.bounds)
            }
            context.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.png
        }
        try data.write(to: url)
    }

    private static func renderPanel(to url: URL) throws {
        let previewDefaults = UserDefaults(suiteName: "battbar.preview") ?? .standard
        previewDefaults.removePersistentDomain(forName: "battbar.preview")
        let model = AppModel(settingsStore: SettingsStore(defaults: previewDefaults))
        model.apply(ScanOutcome(devices: [previewDevices()[0]], issues: [], timestamp: Date()))
        let actions = PanelActions(
            refresh: {},
            selectDevice: { _ in },
            setRefreshInterval: { _ in },
            setLowBatteryAlerts: { _ in },
            setHideWhenFullscreen: { _ in },
            setLaunchAtLogin: { _ in },
            copyDiagnostics: {},
            testNotification: {},
            quit: {}
        )
        print("preview devices=\(model.devices.count) active=\(model.activeDevice?.name ?? "nil")")
        let showSettings = ProcessInfo.processInfo.environment["BATTBAR_PREVIEW_SETTINGS"] == "1"
        let hosting = NSHostingView(rootView: PanelView(model: model, actions: actions, initiallyShowingSettings: showSettings))
        let bounds = NSRect(x: 0, y: 0, width: 372, height: 560)
        hosting.frame = bounds
        hosting.layoutSubtreeIfNeeded()
        // Retina screens show a README image at roughly two device pixels per
        // CSS pixel, so a 2x capture of a 372pt panel is upscaled on every
        // retina display. Render at 4x to stay sharp at that size.
        // cacheDisplay needs an alpha channel: an opaque rep comes out black.
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.render
        }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.png
        }
        try data.write(to: url)
    }

    private enum RenderError: Error {
        case context
        case render
        case png
    }
}
