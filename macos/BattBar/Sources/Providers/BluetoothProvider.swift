import Foundation

/// Reads battery levels for Bluetooth mice that macOS already knows about.
///
/// This type is deliberately thin: it runs `system_profiler`, walks the JSON
/// shape Apple gives us, and hands each device's attributes to the Rust core,
/// which owns the rules (which attribute wins, how charging is spelled, what
/// counts as a mouse, how the stable id is built).
final class BluetoothProvider {
    private var cachedOutcome: ProviderOutcome?
    private var cachedAt: Date?
    private let cacheLifetime: TimeInterval = 120

    func scan(force: Bool = false) -> ProviderOutcome {
        if !force,
           let cachedOutcome,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cachedOutcome
        }

        let outcome = readBluetoothDevices()
        if outcome.issues.isEmpty {
            cachedOutcome = outcome
            cachedAt = Date()
        }
        return outcome
    }

    private func readBluetoothDevices() -> ProviderOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "full"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProviderOutcome(issues: [ProviderIssue(
                provider: .bluetooth,
                code: "BT_PROCESS_FAILED",
                message: "无法读取系统蓝牙电量。",
                detail: error.localizedDescription
            )])
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderOutcome(issues: [ProviderIssue(
                provider: .bluetooth,
                code: "BT_PARSE_FAILED",
                message: "系统蓝牙返回了无法解析的数据。",
                detail: "system_profiler exit \(process.terminationStatus)"
            )])
        }

        let devices = parseBluetoothPayload(payload)
        return ProviderOutcome(devices: devices, issues: [])
    }

    /// Walk `SPBluetoothDataType` and hand every device to the core.
    func parseBluetoothPayload(_ payload: [String: Any]) -> [MouseDevice] {
        let roots: [[String: Any]]
        if let array = payload["SPBluetoothDataType"] as? [[String: Any]] {
            roots = array
        } else if let object = payload["SPBluetoothDataType"] as? [String: Any] {
            roots = [object]
        } else {
            return []
        }

        var seen = Set<String>()
        var result: [MouseDevice] = []
        for root in roots {
            let groups: [[String: Any]]
            if let array = root["device_connected"] as? [[String: Any]] {
                groups = array
            } else if let object = root["device_connected"] as? [String: Any] {
                groups = [object]
            } else {
                continue
            }

            for group in groups {
                for (entryName, raw) in group {
                    guard let attributes = raw as? [String: Any] else { continue }
                    let name = (attributes["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entryName
                    let minorType = attributes["device_minorType"] as? String ?? ""

                    // The core owns the recognition rule.
                    guard CoreBridge.isLikelyMouse(name: name, minorType: minorType) else { continue }
                    guard let battery = CoreBridge.bluetoothBattery(attributes) else { continue }

                    let address = (attributes["device_address"] as? String)?.lowercased() ?? ""
                    let key = address.isEmpty ? name.lowercased() : address
                    guard seen.insert(key).inserted else { continue }

                    let variant = [minorType, address].filter { !$0.isEmpty }.joined(separator: " · ")
                    result.append(MouseDevice(
                        id: CoreBridge.bluetoothDeviceID(address: address, name: name),
                        provider: .bluetooth,
                        name: name,
                        subtitle: variant,
                        connection: .bluetooth,
                        source: "macOS 蓝牙",
                        battery: battery,
                        charging: CoreBridge.bluetoothCharging(attributes),
                        lastSeen: Date(),
                        isStale: false,
                        hardware: ["minorType": minorType, "address": address]
                    ))
                }
            }
        }
        return result
    }
}
