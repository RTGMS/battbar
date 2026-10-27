// Replay core/vectors/vectors.json against the shipped Swift protocol code.
//
// This is the safety net for the migration: it proves that battbar-core keeps
// producing exactly what the already-validated macOS app produces, so the core
// can be swapped in without changing behaviour on real hardware.

import Foundation

// MARK: - Harness

var failures = 0
var checks = 0
var skipped = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

func describe(_ value: Any?) -> String {
    guard let value else { return "nil" }
    return String(describing: value)
}

func hexBytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard next <= hex.endIndex, let byte = UInt8(hex[index..<next], radix: 16) else {
            fputs("bad hex: \(hex)\n", stderr)
            return []
        }
        result.append(byte)
        index = next
    }
    return result
}

func toHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Load vectors

let vectorPath = ProcessInfo.processInfo.environment["BATTBAR_VECTORS"]
    ?? "core/vectors/vectors.json"

guard let vectorData = FileManager.default.contents(atPath: vectorPath),
      let vectors = (try? JSONSerialization.jsonObject(with: vectorData)) as? [String: Any] else {
    fputs("Cannot read vectors at \(vectorPath)\n", stderr)
    exit(2)
}

func targets(_ entry: [String: Any]) -> [String] {
    // A case without an explicit target list must agree on every platform.
    (entry["targets"] as? [String]) ?? ["rust", "swift", "js"]
}

func appliesToSwift(_ entry: [String: Any]) -> Bool {
    targets(entry).contains("swift")
}

// MARK: - ATK

if let atk = vectors["atk"] as? [String: Any] {
    let expectedRequest = atk["request_hex"] as? String ?? ""
    check(
        toHex(ATKProtocol.batteryRequest()) == expectedRequest,
        "ATK request: expected \(expectedRequest), got \(toHex(ATKProtocol.batteryRequest()))"
    )

    for caseEntry in atk["decode"] as? [[String: Any]] ?? [] {
        let label = caseEntry["name"] as? String ?? "<unnamed>"
        guard appliesToSwift(caseEntry) else { skipped += 1; continue }

        let reportID = caseEntry["report_id"] as? Int ?? 0
        let bytes = hexBytes(caseEntry["hex"] as? String ?? "")
        let expect = caseEntry["expect"] as? [String: Any] ?? [:]
        let kind = expect["kind"] as? String ?? ""

        let decoded = ATKProtocol.decode(reportID: reportID, bytes: bytes)

        switch kind {
        case "reading":
            let expectedBattery = expect["battery"] as? Int
            let expectedCharging = expect["charging"] as? Bool
            if case .success(let reading)? = decoded {
                check(Int(reading.battery) == expectedBattery, "ATK \(label): battery expected \(describe(expectedBattery)), got \(reading.battery)")
                check(reading.charging == expectedCharging, "ATK \(label): charging expected \(describe(expectedCharging)), got \(reading.charging)")
            } else {
                check(false, "ATK \(label): expected a reading, got \(describe(decoded))")
            }
        case "status":
            let expectedStatus = UInt8(expect["status"] as? Int ?? -1)
            if case .failure(.invalidStatus(let status))? = decoded {
                check(status == expectedStatus, "ATK \(label): status expected \(expectedStatus), got \(status)")
            } else {
                check(false, "ATK \(label): expected invalidStatus, got \(describe(decoded))")
            }
        case "not_for_us":
            check(decoded == nil, "ATK \(label): expected nil, got \(describe(decoded))")
        default:
            check(false, "ATK \(label): unknown expectation \(kind)")
        }
    }
}

// MARK: - Razer

if let razer = vectors["razer"] as? [String: Any] {
    for caseEntry in razer["requests"] as? [[String: Any]] ?? [] {
        let label = caseEntry["name"] as? String ?? "<unnamed>"
        guard appliesToSwift(caseEntry) else { skipped += 1; continue }

        let commandID = UInt8(caseEntry["command_id"] as? Int ?? 0)
        let request = RazerProtocol.request(
            commandClass: UInt8(caseEntry["command_class"] as? Int ?? 0),
            commandID: commandID
        )
        check(request.count == (razer["report_length"] as? Int ?? 90), "Razer \(label): report length \(request.count)")
        check(request[1] == UInt8(caseEntry["transaction_id"] as? Int ?? 0), "Razer \(label): transaction id")
        check(request[5] == UInt8(caseEntry["data_size"] as? Int ?? 0), "Razer \(label): data size")
        check(request[7] == commandID, "Razer \(label): command id")
        let crcIndex = caseEntry["crc_index"] as? Int ?? 88
        check(request[crcIndex] == UInt8(caseEntry["crc"] as? Int ?? 0), "Razer \(label): crc expected \(caseEntry["crc"] ?? "?"), got \(request[crcIndex])")
    }

    for caseEntry in razer["decode"] as? [[String: Any]] ?? [] {
        let label = caseEntry["name"] as? String ?? "<unnamed>"
        guard appliesToSwift(caseEntry) else { skipped += 1; continue }

        let bytes = hexBytes(caseEntry["hex"] as? String ?? "")
        let expect = caseEntry["expect"] as? [String: Any] ?? [:]
        let kind = expect["kind"] as? String ?? ""

        // Mirrors the accept/reject rules in RazerProvider.sendOnce, which is
        // the only place the shipped app validates a response.
        let status = bytes.count > 0 ? bytes[0] : 0xFF
        let statusOK = status == 0x02 || status == 0x01
        let commandOK = bytes.count > 7
            && bytes[6] == RazerProtocol.commandClass
            && bytes[7] == (kind == "charging" ? RazerProtocol.chargingCommand : RazerProtocol.batteryCommand)

        switch kind {
        case "battery", "charging":
            check(!bytes.isEmpty && statusOK, "Razer \(label): expected an accepted status, got \(status)")
            check(commandOK, "Razer \(label): expected a matching command")
            if kind == "battery" {
                let expected = expect["battery"] as? Int
                check(RazerProtocol.battery(from: bytes) == expected, "Razer \(label): battery expected \(describe(expected)), got \(describe(RazerProtocol.battery(from: bytes)))")
            } else {
                let expected = expect["charging"] as? Bool
                check(RazerProtocol.charging(from: bytes) == expected, "Razer \(label): charging expected \(describe(expected)), got \(describe(RazerProtocol.charging(from: bytes)))")
            }
        case "status":
            check(!statusOK, "Razer \(label): expected a rejected status, got \(status)")
        case "not_for_us":
            check(!commandOK, "Razer \(label): expected a command mismatch")
        default:
            check(false, "Razer \(label): unknown expectation \(kind)")
        }
    }
}

// MARK: - Bluetooth attributes

if let bluetooth = vectors["bluetooth"] as? [String: Any] {
    let provider = BluetoothProvider()

    /// Wrap a flat attribute list into the `system_profiler` shape the shipped
    /// parser consumes, then read the result back.
    func parse(attributes: [[String]], chargingInclude: Bool) -> MouseDevice? {
        var device: [String: Any] = [:]
        for pair in attributes where pair.count == 2 {
            device[pair[0]] = pair[1]
        }
        // Always give the device a battery so it survives the filter, then the
        // attribute under test decides the value we read.
        if device["device_batteryLevelMain"] == nil && chargingInclude {
            device["device_batteryLevelMain"] = "50%"
        }
        device["device_name"] = "Test Mouse"
        device["device_minorType"] = "Mouse"

        let payload: [String: Any] = [
            "SPBluetoothDataType": [
                ["device_connected": [["Test Mouse": device]]]
            ]
        ]
        return provider.parseBluetoothPayload(payload).first
    }

    for caseEntry in bluetooth["battery_attributes"] as? [[String: Any]] ?? [] {
        let label = caseEntry["name"] as? String ?? "<unnamed>"
        guard appliesToSwift(caseEntry) else { skipped += 1; continue }

        let attributes = caseEntry["attributes"] as? [[String]] ?? []
        let expected = caseEntry["expect"] as? Int
        let actual = parse(attributes: attributes, chargingInclude: false)?.battery
        check(actual == expected, "Bluetooth \(label): battery expected \(describe(expected)), got \(describe(actual))")
    }

    for caseEntry in bluetooth["charging_attributes"] as? [[String: Any]] ?? [] {
        let label = caseEntry["name"] as? String ?? "<unnamed>"
        guard appliesToSwift(caseEntry) else { skipped += 1; continue }

        let attributes = caseEntry["attributes"] as? [[String]] ?? []
        let expected = caseEntry["expect"] as? Bool
        let actual = parse(attributes: attributes, chargingInclude: true)?.charging
        check(actual == expected, "Bluetooth \(label): charging expected \(describe(expected)), got \(describe(actual))")
    }
}

// MARK: - Summary

print("swift cross-check: \(checks) checks, \(failures) failure(s), \(skipped) skipped")
exit(failures == 0 ? 0 : 1)
