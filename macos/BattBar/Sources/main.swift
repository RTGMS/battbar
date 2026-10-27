import AppKit
import Foundation
import IOKit.hid

if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    let directory = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "."
    let code = MainActor.assumeIsolated { PreviewRenderer.run(outputDirectory: directory) }
    exit(code)
}

if CommandLine.arguments.contains("--probe") {
    let hid = DispatchSemaphore(value: 0)
    var result: ProviderOutcome!
    let thread = Thread {
        var combined = ProviderOutcome()
        combined.merge(AtkProvider().scan())
        combined.merge(RazerProvider().scan())
        result = combined
        hid.signal()
    }
    thread.start()
    hid.wait()
    let bt = BluetoothProvider().scan(force: true)
    result.merge(bt)
    for device in result.devices.sorted(by: { $0.provider.priority < $1.provider.priority }) {
        print("DEVICE: \(device.provider.rawValue) | \(device.name) | \(device.batteryText) | \(device.connectionLabel) | stale=\(device.isStale)")
    }
    for issue in result.issues {
        print("ISSUE: \(issue.provider.rawValue) | \(issue.code) | \(issue.message) | \(issue.detail ?? "")")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
