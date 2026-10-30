import Foundation
import IOKit.hid

/// Razer Viper V3 Pro over the 2.4G receiver.
///
/// Razer devices speak a 90-byte HID feature-report protocol. The command
/// layout and transaction IDs below follow OpenRazer's razercommon /
/// razermouse_driver implementation:
///   battery  = command class 0x07, command id 0x80, data size 2
///   charging = command class 0x07, command id 0x84, data size 2
/// The battery value in the response is a 0...255 value scaled to 0...100.
final class RazerProvider {
    static let vendorID = 0x1532
    static let supportedPIDs: Set<Int> = [0x00C1, 0x00B3]
    private static let waitPerCommand: TimeInterval = 0.065

    func scan() -> ProviderOutcome {
        let session = HIDEnumerationSession(vendorIDs: [Self.vendorID])
        let candidates = session.devices.filter {
            Self.supportedPIDs.contains($0.productID)
        }

        guard !candidates.isEmpty else { return ProviderOutcome() }

        var issues: [ProviderIssue] = []
        var lastError: Error?

        for candidate in candidates {
            if let reading = try? readBattery(descriptor: candidate) {
                return ProviderOutcome(
                    devices: [Self.makeDevice(descriptor: candidate, reading: reading)],
                    issues: []
                )
            } else {
                lastError = HIDError.timeout
            }
        }

        issues.append(ProviderIssue(
            provider: .razer,
            code: "RAZER_NO_RESPONSE",
            message: "检测到雷蛇接收器，但暂时没有读到电量。",
            detail: "\(lastError?.localizedDescription ?? "设备未响应")。Razer 支持仍处于验证阶段，请将鼠标唤醒后重试。"
        ))
        return ProviderOutcome(devices: [], issues: issues)
    }

    private struct RazerReading {
        let battery: Int
        let charging: Bool?
    }

    private func readBattery(descriptor: HIDDeviceDescriptor) throws -> RazerReading {
        let device = descriptor.device
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw HIDError.openFailed(openResult) }
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        let batteryResponse = try sendRequest(
            commandClass: RazerProtocol.commandClass,
            commandID: RazerProtocol.batteryCommand,
            to: device
        )
        guard let battery = RazerProtocol.battery(from: batteryResponse) else {
            throw HIDError.invalidResponse("Razer 电量数据不完整")
        }

        var charging: Bool?
        if let chargingResponse = try? sendRequest(
            commandClass: RazerProtocol.commandClass,
            commandID: RazerProtocol.chargingCommand,
            to: device
        ) {
            charging = RazerProtocol.charging(from: chargingResponse)
        }

        return RazerReading(battery: battery, charging: charging)
    }

    private func sendRequest(commandClass: UInt8, commandID: UInt8, to device: IOHIDDevice) throws -> [UInt8] {
        var lastError: Error = HIDError.timeout
        for attempt in 0..<5 {
            do {
                return try sendOnce(commandClass: commandClass, commandID: commandID, to: device)
            } catch {
                lastError = error
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: 0.012)
                }
            }
        }
        throw lastError
    }

    private func sendOnce(commandClass: UInt8, commandID: UInt8, to device: IOHIDDevice) throws -> [UInt8] {
        let request = RazerProtocol.request(commandClass: commandClass, commandID: commandID)

        let setResult = request.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                0,
                $0.baseAddress!,
                CFIndex(RazerProtocol.reportLength)
            )
        }
        guard setResult == kIOReturnSuccess else { throw HIDError.writeFailed(setResult) }

        Thread.sleep(forTimeInterval: Self.waitPerCommand)

        var response = [UInt8](repeating: 0, count: RazerProtocol.reportLength + 1)
        var responseLength = CFIndex(RazerProtocol.reportLength)
        let getResult = response.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                0,
                $0.baseAddress!,
                &responseLength
            )
        }
        guard getResult == kIOReturnSuccess else { throw HIDError.readFailed(getResult) }
        guard responseLength >= 10 else {
            throw HIDError.invalidResponse("Razer 返回的报告长度不足（\(responseLength) 字节）")
        }
        // 0x02 = successful, 0x01 = busy (the device still returns valid args).
        guard response[0] == 0x02 || response[0] == 0x01 else {
            throw HIDError.invalidResponse("Razer 返回状态 0x\(String(response[0], radix: 16))")
        }
        guard response[6] == commandClass, response[7] == commandID else {
            throw HIDError.invalidResponse("Razer 返回的命令不匹配")
        }
        return response
    }

    private static func makeDevice(descriptor: HIDDeviceDescriptor, reading: RazerReading) -> MouseDevice {
        // Known models and the "型号未知" fallback are core rules.
        let display = CoreBridge.razerDisplayName(product: descriptor.product, productID: descriptor.productID)
        return MouseDevice(
            id: CoreBridge.razerDeviceID(vendorID: descriptor.vendorID, productID: descriptor.productID),
            provider: .razer,
            name: display.name,
            subtitle: display.subtitle,
            connection: .receiver,
            source: "Razer HID",
            battery: reading.battery,
            charging: reading.charging,
            lastSeen: Date(),
            isStale: false,
            hardware: [
                "vid": String(format: "0x%04X", descriptor.vendorID),
                "pid": String(format: "0x%04X", descriptor.productID),
                "product": descriptor.product,
                "transaction": String(format: "0x%02X", RazerProtocol.transactionID),
            ]
        )
    }
}
