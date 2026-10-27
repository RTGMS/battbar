import Foundation

final class BluetoothProvider {
    private var cachedOutcome: ProviderOutcome?
    private var cachedAt: Date?
    private let cacheLifetime: TimeInterval = 120
    private let mousePattern = try! NSRegularExpression(
        pattern: "mouse|mice|鼠标|atk|vxe|mad\\s*r|razer|雷蛇|logitech|罗技|pulsar|lamzu|ninja|glorious|zowie|benq|steelseries|赛睿|roccat|corsair|海盗船|hyperx|pwnage|finalmouse|endgame|mx\\s*(master|anywhere)|deathadder|viper|basilisk|aerox|rival",
        options: [.caseInsensitive]
    )

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
                    guard isMouse(name: name, minorType: minorType) else { continue }
                    guard let battery = batteryLevel(attributes) else { continue }
                    let address = (attributes["device_address"] as? String)?.lowercased() ?? ""
                    let key = address.isEmpty ? name.lowercased() : address
                    guard seen.insert(key).inserted else { continue }

                    let id: String
                    if address.isEmpty {
                        id = "bt-macos:\(name.lowercased())"
                    } else {
                        id = "bt-macos:\(address)"
                    }
                    let variant = [minorType, address].filter { !$0.isEmpty }.joined(separator: " · ")
                    result.append(MouseDevice(
                        id: id,
                        provider: .bluetooth,
                        name: name,
                        subtitle: variant,
                        connection: .bluetooth,
                        source: "macOS 蓝牙",
                        battery: battery,
                        charging: chargingState(attributes),
                        lastSeen: Date(),
                        isStale: false,
                        hardware: ["minorType": minorType, "address": address]
                    ))
                }
            }
        }
        return result
    }

    private func isMouse(name: String, minorType: String) -> Bool {
        if minorType.localizedCaseInsensitiveContains("mouse")
            || minorType.localizedCaseInsensitiveContains("pointing") {
            return true
        }
        let haystack = name + " " + minorType
        let range = NSRange(location: 0, length: haystack.utf16.count)
        return mousePattern.firstMatch(in: haystack, range: range) != nil
    }

    private func batteryLevel(_ attributes: [String: Any]) -> Int? {
        let preferred = [
            "device_batteryLevelMain",
            "device_batteryLevel",
            "device_batteryPercent",
            "device_batteryLevelCombined",
        ]
        for key in preferred {
            if let value = parsePercent(attributes[key]) { return value }
        }
        for (key, value) in attributes where key.lowercased().hasPrefix("device_battery") {
            if key.lowercased().contains("case") || key.lowercased().contains("left")
                || key.lowercased().contains("right") || key.lowercased().contains("secondary") {
                continue
            }
            if let parsed = parsePercent(value) { return parsed }
        }
        return nil
    }

    private func parsePercent(_ raw: Any?) -> Int? {
        let number: Int?
        if let value = raw as? Int {
            number = value
        } else if let value = raw as? NSNumber {
            number = value.intValue
        } else if let value = raw as? String {
            let scanner = Foundation.Scanner(string: value)
            number = scanner.scanInt()
        } else {
            number = nil
        }
        guard let number, (0...100).contains(number) else { return nil }
        return number
    }

    private func chargingState(_ attributes: [String: Any]) -> Bool? {
        for key in ["device_charging", "device_batteryCharging", "charging"] {
            guard let value = attributes[key] else { continue }
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String {
                let normalized = string.lowercased()
                if ["yes", "true", "1", "charging"].contains(normalized) { return true }
                if ["no", "false", "0", "discharging"].contains(normalized) { return false }
            }
        }
        return nil
    }
}
