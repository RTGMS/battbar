import Foundation
import IOKit.hid

final class AtkProvider {
    static let vendorIDs: [Int] = [0x373b, 0x3554]
    private static let readWindow: TimeInterval = 1.4

    func scan() -> ProviderOutcome {
        let session = HIDEnumerationSession(vendorIDs: Self.vendorIDs)
        let candidates = session.devices.filter { descriptor in
            descriptor.primaryUsagePage >= 0xff00
        }

        guard !candidates.isEmpty else { return ProviderOutcome() }

        var devices: [MouseDevice] = []
        var issues: [ProviderIssue] = []
        var lastError: Error?

        for candidate in candidates {
            if let reading = readWithRetry(candidate) {
                devices.append(Self.makeDevice(descriptor: candidate, reading: reading))
                lastError = nil
                break
            } else {
                lastError = HIDError.timeout
            }
        }

        if devices.isEmpty, let lastError {
            issues.append(ProviderIssue(
                provider: .atk,
                code: "ATK_TIMEOUT",
                message: "ATK 接收器已连接，但鼠标没有响应。",
                detail: "\(lastError.localizedDescription)。请唤醒鼠标或关闭 ATK HUB 后重试。"
            ))
        }

        return ProviderOutcome(devices: devices, issues: issues)
    }

    private func readWithRetry(_ descriptor: HIDDeviceDescriptor) -> ATKReading? {
        for attempt in 0..<2 {
            if let reading = try? read(descriptor) {
                return reading
            }
            if attempt == 0 {
                Thread.sleep(forTimeInterval: 0.18)
            }
        }
        return nil
    }

    private func read(_ descriptor: HIDDeviceDescriptor) throws -> ATKReading {
        let device = descriptor.device
        let debug = ProcessInfo.processInfo.environment["MOUSEBATTERY_DEBUG"] == "1"
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if debug { print("[ATK] open \(descriptor.product) page=0x\(String(descriptor.primaryUsagePage, radix: 16)) usage=0x\(String(descriptor.primaryUsage, radix: 16)) -> 0x\(String(openResult, radix: 16))") }
        guard openResult == kIOReturnSuccess else { throw HIDError.openFailed(openResult) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let bufferLength = max(64, hidInt(device, kIOHIDMaxInputReportSizeKey) ?? 0)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        buffer.initialize(repeating: 0, count: bufferLength)
        defer { buffer.deallocate() }

        let state = ATKReadState()
        let context = Unmanaged.passUnretained(state).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferLength,
            { context, _, _, _, reportID, report, reportLength in
                guard let context else { return }
                let state = Unmanaged<ATKReadState>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                if ProcessInfo.processInfo.environment["MOUSEBATTERY_DEBUG"] == "1" {
                    print("[ATK] report id=\(reportID) len=\(reportLength) hex=\(bytes.prefix(20).map { String(format: "%02x", $0) }.joined())")
                }
                state.handle(reportID: Int(reportID), bytes: bytes)
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferLength, nil, nil)
        }

        // IOHIDDeviceSetReport wants the report ID as the first byte of the
        // buffer for devices with numbered reports (HIDAPI passes it through).
        let packet = ATKProtocol.batteryRequest()

        let writeResult = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(0x08),
                $0.baseAddress!,
                CFIndex(packet.count)
            )
        }
        if debug { print("[ATK] write -> 0x\(String(writeResult, radix: 16)) packet=\(packet.map { String(format: "%02x", $0) }.joined())") }
        guard writeResult == kIOReturnSuccess else { throw HIDError.writeFailed(writeResult) }

        let deadline = Date().addingTimeInterval(Self.readWindow)
        while !state.isFinished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        if let message = state.invalidMessage {
            throw HIDError.invalidResponse(message)
        }
        guard let reading = state.reading else { throw HIDError.timeout }
        return reading
    }

    private static func makeDevice(descriptor: HIDDeviceDescriptor, reading: ATKReading) -> MouseDevice {
        let product = descriptor.product.isEmpty ? "ATK Mouse" : descriptor.product
        let brand: String
        if product.localizedCaseInsensitiveContains("vxe") { brand = "VXE" }
        else if product.localizedCaseInsensitiveContains("mad") { brand = "MAD" }
        else { brand = "ATK" }
        let isDongle = product.localizedCaseInsensitiveContains("dongle")
            || product.localizedCaseInsensitiveContains("receiver")
        let displayName = isDongle ? "\(brand) 无线鼠标" : product
        let serial = descriptor.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let idSuffix = serial.isEmpty ? String(format: "%04x-%04x", descriptor.vendorID, descriptor.productID) : serial
        return MouseDevice(
            id: "atk:\(descriptor.vendorID):\(descriptor.productID):\(idSuffix)",
            provider: .atk,
            name: displayName,
            subtitle: product,
            connection: .receiver,
            source: "ATK HID",
            battery: reading.battery,
            charging: reading.charging,
            lastSeen: Date(),
            isStale: false,
            hardware: [
                "vid": String(format: "0x%04X", descriptor.vendorID),
                "pid": String(format: "0x%04X", descriptor.productID),
                "product": product,
                "usagePage": String(format: "0x%04X", descriptor.primaryUsagePage),
            ]
        )
    }
}

private final class ATKReadState {
    var reading: ATKReading?
    var invalidMessage: String?
    var isFinished = false

    func handle(reportID: Int, bytes: [UInt8]) {
        guard !isFinished else { return }
        guard let decoded = ATKProtocol.decode(reportID: reportID, bytes: bytes) else { return }
        switch decoded {
        case .success(let value):
            reading = value
            isFinished = true
        case .failure(.invalidStatus(let status)):
            invalidMessage = "ATK 设备返回状态码 0x\(String(status, radix: 16))"
            isFinished = true
        }
    }
}
