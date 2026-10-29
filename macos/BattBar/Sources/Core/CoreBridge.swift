import Foundation

/// Typed wrappers over the Rust core's C ABI.
///
/// Everything here is marshalling: pointers in, Swift values out. Protocol
/// rules, thresholds, ordering and parsing live in `core/`; UI text and OS APIs
/// stay in the platform layer.
enum CoreBridge {
    // MARK: - Bluetooth rules

    static func isLikelyMouse(name: String, minorType: String) -> Bool {
        name.withCString { namePointer in
            minorType.withCString { minorPointer in
                battbar_bluetooth_is_likely_mouse(namePointer, minorPointer) == 1
            }
        }
    }

    static func bluetoothBattery(_ attributes: [String: Any]) -> Int? {
        let pairs = flatten(attributes)
        let result = withAttributePairs(pairs) { count, keys, values in
            battbar_bluetooth_battery(count, keys, values)
        }
        return result >= 0 ? Int(result) : nil
    }

    static func bluetoothCharging(_ attributes: [String: Any]) -> Bool? {
        let pairs = flatten(attributes)
        let result = withAttributePairs(pairs) { count, keys, values in
            battbar_bluetooth_charging(count, keys, values)
        }
        switch result {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }

    static func bluetoothDeviceID(address: String, name: String) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = address.withCString { addressPointer in
            name.withCString { namePointer in
                buffer.withUnsafeMutableBufferPointer {
                    battbar_bluetooth_macos_id(addressPointer, namePointer, $0.baseAddress, $0.count)
                }
            }
        }
        guard written > 0 else { return "bt-macos:\(name.lowercased())" }
        return String(cString: buffer)
    }

    // MARK: - Device selection

    /// Whether an IOKit-enumerated device should be opened (macOS enumeration
    /// model: one entry per device, primary usage page only).
    static func isATKCandidate(vendorID: Int, usagePage: Int, usage: Int) -> Bool {
        battbar_atk_is_macos_candidate(
            UInt16(truncatingIfNeeded: vendorID),
            UInt16(truncatingIfNeeded: usagePage),
            UInt16(truncatingIfNeeded: usage)
        ) == 1
    }

    // MARK: - Scan merge

    struct MergedDevices {
        let devices: [MouseDevice]
        let activeID: String?
    }

    /// Apply the core's retention/ordering policy to one scan.
    ///
    /// The ABI returns indices into the inputs rather than copies of the
    /// devices, so the models are rebuilt here from the caller's own arrays.
    static func merge(
        fresh: [MouseDevice],
        previous: [MouseDevice],
        failedProviders: Set<DeviceProviderKind>,
        selectedID: String?
    ) -> MergedDevices {
        guard !fresh.isEmpty || !previous.isEmpty else {
            return MergedDevices(devices: [], activeID: nil)
        }

        // Ids and names alternate so their C strings can share one flat buffer.
        let freshStrings = fresh.flatMap { [$0.id, $0.name] }
        let previousStrings = previous.flatMap { [$0.id, $0.name] }

        return withCStrings(freshStrings) { freshPointers in
            withCStrings(previousStrings) { previousPointers in
                withCStrings([selectedID ?? ""]) { selectedPointers in
                    merge(
                        fresh: fresh,
                        freshPointers: freshPointers,
                        previous: previous,
                        previousPointers: previousPointers,
                        failedProviders: failedProviders,
                        selectedPointer: selectedPointers[0]
                    )
                }
            }
        }
    }

    private static func merge(
        fresh: [MouseDevice],
        freshPointers: [UnsafePointer<CChar>],
        previous: [MouseDevice],
        previousPointers: [UnsafePointer<CChar>],
        failedProviders: Set<DeviceProviderKind>,
        selectedPointer: UnsafePointer<CChar>
    ) -> MergedDevices {
        let freshSummaries = summaries(fresh, freshPointers)
        let previousSummaries = summaries(previous, previousPointers)
        let failed = failedProviders.map { Int32($0.priority) }

        var entries = [BattbarMergedDevice](
            repeating: BattbarMergedDevice(),
            count: fresh.count + previous.count
        )
        var count: Int32 = 0
        var active: Int32 = -1

        let status = entries.withUnsafeMutableBufferPointer { entryBuffer in
            freshSummaries.withUnsafeBufferPointer { freshBuffer in
                previousSummaries.withUnsafeBufferPointer { previousBuffer in
                    failed.withUnsafeBufferPointer { failedBuffer in
                        battbar_merge_scan(
                            freshBuffer.baseAddress, Int32(fresh.count),
                            previousBuffer.baseAddress, Int32(previous.count),
                            failedBuffer.baseAddress, Int32(failed.count),
                            selectedPointer,
                            entryBuffer.baseAddress,
                            &count,
                            &active
                        )
                    }
                }
            }
        }
        guard status == 0 else {
            // Never blank the UI if the core rejects the input.
            return MergedDevices(devices: fresh, activeID: fresh.first?.id)
        }

        var merged: [MouseDevice] = []
        merged.reserveCapacity(Int(count))
        for entry in entries.prefix(Int(count)) {
            let source = entry.from_previous == 1 ? previous : fresh
            let index = Int(entry.index)
            guard source.indices.contains(index) else { continue }
            var device = source[index]
            device.isStale = entry.stale == 1
            merged.append(device)
        }

        let activeIndex = Int(active)
        let activeID = merged.indices.contains(activeIndex)
            ? merged[activeIndex].id
            : merged.first?.id
        return MergedDevices(devices: merged, activeID: activeID)
    }

    /// Build the C structs from alternating id/name pointers.
    private static func summaries(
        _ devices: [MouseDevice],
        _ pointers: [UnsafePointer<CChar>]
    ) -> [BattbarDeviceSummary] {
        var result: [BattbarDeviceSummary] = []
        result.reserveCapacity(devices.count)
        for (index, device) in devices.enumerated() {
            result.append(BattbarDeviceSummary(
                id: pointers[index * 2],
                name: pointers[index * 2 + 1],
                provider: Int32(device.provider.priority),
                connection: device.connection == .receiver ? 0 : 1
            ))
        }
        return result
    }

    // MARK: - Retry policy

    /// Delay before the single retry of a dropped scan, or nil when the next
    /// scheduled poll should be the only remaining attempt.
    static func retryDelayMilliseconds(hasStaleDevice: Bool, alreadyRetried: Bool) -> Int? {
        let delay = battbar_retry_delay_ms(hasStaleDevice ? 1 : 0, alreadyRetried ? 1 : 0)
        return delay < 0 ? nil : Int(delay)
    }

    // MARK: - Helpers

    /// `system_profiler` hands us typed values; the core wants strings.
    private static func flatten(_ attributes: [String: Any]) -> [(String, String)] {
        attributes.compactMap { key, value in
            guard let text = stringify(value) else { return nil }
            return (key, text)
        }
    }

    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Call `body` with C-string pointers that stay valid for its duration.
    static func withCStrings<T>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>]) -> T
    ) -> T {
        var flat: [CChar] = []
        var offsets: [Int] = []
        offsets.reserveCapacity(strings.count)
        for string in strings {
            offsets.append(flat.count)
            flat.append(contentsOf: string.utf8CString)
        }
        return flat.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return body([]) }
            let pointers = offsets.map { UnsafePointer(base.advanced(by: $0)) }
            return body(pointers)
        }
    }

    private static func withAttributePairs<T>(
        _ pairs: [(String, String)],
        _ body: (Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?) -> T
    ) -> T {
        let flat = pairs.flatMap { [$0.0, $0.1] }
        return withCStrings(flat) { pointers in
            var keys: [UnsafePointer<CChar>?] = []
            var values: [UnsafePointer<CChar>?] = []
            keys.reserveCapacity(pairs.count)
            values.reserveCapacity(pairs.count)
            for index in 0..<pairs.count {
                keys.append(pointers[index * 2])
                values.append(pointers[index * 2 + 1])
            }
            return keys.withUnsafeBufferPointer { keyBuffer in
                values.withUnsafeBufferPointer { valueBuffer in
                    body(Int32(pairs.count), keyBuffer.baseAddress, valueBuffer.baseAddress)
                }
            }
        }
    }
}

/// One alert the core decided to raise.
struct CoreAlert {
    enum Kind {
        case low
        case critical
    }

    let kind: Kind
    let deviceID: String
    let battery: Int
}

/// Low-battery de-duplication state, owned by the Rust core.
final class CoreAlertManager {
    private var handle: OpaquePointer?

    init() {
        handle = battbar_alerts_new()
    }

    deinit {
        if let handle { battbar_alerts_free(handle) }
    }

    /// Ask the core which devices need a notification right now.
    func evaluate(_ devices: [MouseDevice], enabled: Bool) -> [CoreAlert] {
        guard let handle, !devices.isEmpty else { return [] }

        return CoreBridge.withCStrings(devices.map(\.id)) { pointers in
            var entries: [BattbarAlertDevice] = []
            entries.reserveCapacity(devices.count)
            for (index, device) in devices.enumerated() {
                let charging: Int32
                switch device.charging {
                case .some(true): charging = 1
                case .some(false): charging = 0
                case .none: charging = -1
                }
                entries.append(BattbarAlertDevice(
                    id: pointers[index],
                    battery: device.battery.map { Int32($0) } ?? -1,
                    charging: charging,
                    stale: device.isStale ? 1 : 0
                ))
            }

            var kinds = [UInt8](repeating: 0, count: devices.count)
            let status = entries.withUnsafeBufferPointer { entryBuffer in
                kinds.withUnsafeMutableBufferPointer { kindBuffer in
                    battbar_alerts_evaluate(
                        handle,
                        entryBuffer.baseAddress,
                        Int32(devices.count),
                        enabled ? 1 : 0,
                        kindBuffer.baseAddress
                    )
                }
            }
            guard status == 0 else { return [] }

            var alerts: [CoreAlert] = []
            for (index, kind) in kinds.enumerated() where kind != 0 {
                alerts.append(CoreAlert(
                    kind: kind == 2 ? .critical : .low,
                    deviceID: devices[index].id,
                    battery: devices[index].battery ?? 0
                ))
            }
            return alerts
        }
    }
}
