import Foundation

extension ProviderOutcome {
    mutating func merge(_ other: ProviderOutcome) {
        devices.append(contentsOf: other.devices)
        issues.append(contentsOf: other.issues)
    }
}

final class Scanner {
    let model: AppModel
    var onScanCompleted: ((ScanOutcome) -> Void)?

    private let queue = DispatchQueue(label: "com.mousebattery.scanner", qos: .utility)
    private let bluetoothProvider = BluetoothProvider()
    private var scanning = false

    init(model: AppModel) {
        self.model = model
    }

    func scan(forceBluetooth: Bool = false) {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.main.async { [weak self] in self?.model.beginScan() }

        queue.async { [weak self] in
            guard let self else { return }
            let hid = self.scanHIDProviders()
            let bluetooth = self.bluetoothProvider.scan(force: forceBluetooth)
            var combined = ProviderOutcome()
            combined.merge(hid)
            combined.merge(bluetooth)

            let outcome = ScanOutcome(
                devices: combined.devices,
                issues: combined.issues,
                timestamp: Date()
            )

            DispatchQueue.main.async {
                self.scanning = false
                self.model.apply(outcome)
                self.onScanCompleted?(outcome)
            }
        }
    }

    private func scanHIDProviders() -> ProviderOutcome {
        var result = ProviderOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            autoreleasepool {
                var combined = ProviderOutcome()
                combined.merge(AtkProvider().scan())
                combined.merge(RazerProvider().scan())
                result = combined
            }
            semaphore.signal()
        }
        thread.name = "MouseBattery.HIDScanner"
        thread.qualityOfService = .utility
        thread.start()
        semaphore.wait()
        return result
    }
}
