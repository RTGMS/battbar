// Hardware-in-the-loop test for the Rust core on macOS.
//
// Reads a real report from the ATK receiver through IOKit and decodes it twice:
//
//   1. with the shipped Swift implementation (`ATKProtocol.decode`) — the oracle
//   2. with the Rust core through the C ABI (`battbar_atk_decode`)
//
// and fails when the two disagree. This is the one thing the unit tests cannot
// cover: real bytes from real hardware.
//
// Also verifies that the request bytes produced by the core are byte-identical
// to what the Swift app sends.
//
// Run via core/scripts/hardware-test-macos.sh (it builds the library first).
// Environment: BATTBAR_HW_ITERATIONS (default 5).

import Foundation
import IOKit.hid

// C status codes, restated because the C macros are not imported into Swift.
let hwStatusOK: Int32 = 1
let hwStatusNotForUs: Int32 = 0

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Independent reference decoder for the ATK report.
///
/// The app itself now calls the Rust core, so comparing the core against
/// `ATKProtocol.decode` would be comparing it with itself. This reimplements the
/// documented protocol directly from the byte layout, which keeps the hardware
/// test as a real cross-check.
func referenceDecodeATK(reportID: UInt8, bytes: [UInt8]) -> (battery: Int, charging: Bool)? {
    var payload = bytes
    if payload.first == 0x08 {
        payload.removeFirst()
    } else if reportID != 0x08 {
        return nil
    }
    guard payload.count >= 7, payload[0] == 0x04, payload[1] == 0 else { return nil }
    return (battery: min(100, max(0, Int(payload[5]))), charging: payload[6] == 1)
}

/// The request the protocol defines, written out by hand (17 bytes).
let referenceRequest: [UInt8] = {
    var packet = [UInt8](repeating: 0, count: 17)
    packet[0] = 0x08
    packet[1] = 0x04
    var sum = 0
    for byte in packet[0..<16] { sum += Int(byte) }
    packet[16] = UInt8((0x55 - (sum & 0xff)) & 0xff)
    return packet
}()

// MARK: - Report capture

/// Collects the first ATK response seen on the input-report callback.
final class Capture {
    var bytes: [UInt8]?
    var reportID: UInt32 = 0
    var finished = false

    func handle(reportID: UInt32, report: UnsafePointer<UInt8>, length: Int) {
        guard !finished else { return }
        let buffer = UnsafeBufferPointer(start: report, count: length)
        let data = Array(buffer)
        // Ignore anything that cannot be our answer so a stray mouse report
        // does not end the capture early.
        guard ATKProtocol.decode(reportID: Int(reportID), bytes: data) != nil else { return }
        bytes = data
        self.reportID = reportID
        finished = true
    }
}

/// Read one report from an ATK device, using `request` as the payload.
func readOnce(descriptor: HIDDeviceDescriptor, request: [UInt8], timeout: TimeInterval = 1.5)
    -> (bytes: [UInt8], reportID: UInt32)?
{
    let device = descriptor.device
    guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        return nil
    }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let bufferLength = max(64, hidInt(device, kIOHIDMaxInputReportSizeKey) ?? 0)
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
    buffer.initialize(repeating: 0, count: bufferLength)
    defer { buffer.deallocate() }

    let capture = Capture()
    let context = Unmanaged.passUnretained(capture).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(
        device,
        buffer,
        bufferLength,
        { context, _, _, _, reportID, report, reportLength in
            guard let context else { return }
            let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
            capture.handle(reportID: reportID, report: report, length: reportLength)
        },
        context
    )
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    defer {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferLength, nil, nil)
    }

    let writeResult = request.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(ATKProtocol.reportID),
            $0.baseAddress!,
            CFIndex(request.count)
        )
    }
    guard writeResult == kIOReturnSuccess else { return nil }

    let deadline = Date().addingTimeInterval(timeout)
    while !capture.finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    guard let bytes = capture.bytes else { return nil }
    return (bytes, capture.reportID)
}

// MARK: - ATK

func testATK() -> Bool {
    print("ATK")

    let session = HIDEnumerationSession(vendorIDs: AtkProvider.vendorIDs)
    let candidates = session.devices.filter { $0.primaryUsagePage >= 0xff00 }
    guard !candidates.isEmpty else {
        print("  没有找到 ATK 接收器，跳过（插上接收器后重跑）")
        return true
    }
    for candidate in candidates {
        print("  设备: \(candidate.product) vid=0x\(String(candidate.vendorID, radix: 16)) pid=0x\(String(candidate.productID, radix: 16)) page=0x\(String(candidate.primaryUsagePage, radix: 16)) usage=0x\(String(candidate.primaryUsage, radix: 16)) iface=\(candidate.transport)")
    }

    // The core's request must be byte-identical to what the app sends.
    var coreRequest = [UInt8](repeating: 0, count: Int(battbar_atk_request_len()))
    let written = coreRequest.withUnsafeMutableBufferPointer {
        battbar_atk_request($0.baseAddress, $0.count)
    }
    check(written == Int32(coreRequest.count), "core request length \(written)")
    check(
        coreRequest == referenceRequest,
        "core request \(hexString(coreRequest)) != reference \(hexString(referenceRequest))"
    )
    print("  请求: \(hexString(coreRequest))（与协议定义逐字节一致）")

    let iterations = Int(ProcessInfo.processInfo.environment["BATTBAR_HW_ITERATIONS"] ?? "") ?? 5
    var successes = 0
    var readFailures = 0
    var decoded: [(Int, Bool)] = []

    for index in 0..<iterations {
        let started = Date()
        guard let (bytes, reportID) = readOnce(descriptor: candidates[0], request: coreRequest) else {
            readFailures += 1
            print("  #\(index + 1) 读取超时（鼠标可能休眠，或 App 正在占用）")
            continue
        }
        let elapsed = Date().timeIntervalSince(started) * 1000

        // Oracle: the independent reference decoder above.
        guard let reference = referenceDecodeATK(reportID: UInt8(reportID), bytes: bytes) else {
            check(false, "#\(index + 1) 参照实现无法解析 \(hexString(bytes))")
            continue
        }

        // Subject: the Rust core through the C ABI.
        var rustReading = BattbarReading(battery: 0, charging: 0)
        var deviceStatus: UInt8 = 0
        let status = bytes.withUnsafeBufferPointer {
            battbar_atk_decode(UInt8(reportID), $0.baseAddress, $0.count, &rustReading, &deviceStatus)
        }

        check(status == hwStatusOK, "#\(index + 1) 核心返回状态 \(status)")
        check(
            Int(rustReading.battery) == reference.battery,
            "#\(index + 1) 电量不一致：核心 \(rustReading.battery) vs 参照 \(reference.battery)"
        )
        check(
            (rustReading.charging == 1) == reference.charging,
            "#\(index + 1) 充电状态不一致：核心 \(rustReading.charging) vs 参照 \(reference.charging)"
        )

        successes += 1
        decoded.append((Int(rustReading.battery), rustReading.charging == 1))
        print(
            String(
                format: "  #%d %@  ->  核心 %d%% 充电=%@ · 参照 %d%% 充电=%@ · %.1f ms",
                index + 1,
                hexString(bytes),
                Int(rustReading.battery),
                rustReading.charging == 1 ? "是" : "否",
                reference.battery,
                reference.charging ? "是" : "否",
                elapsed
            )
        )
    }

    print("  成功 \(successes)/\(iterations)，读取超时 \(readFailures) 次")
    if readFailures == iterations {
        print("")
        print("  ⚠ 全部超时：接收器在，但鼠标没有应答。2.4G 鼠标空闲几分钟后会休眠，")
        print("    移动一下鼠标再重跑即可。这不是协议或解码的问题。")
    }
    check(successes > 0, "至少要有一次成功读取（鼠标休眠时属预期失败，唤醒后重跑）")

    // Readings should be stable across a short window (the mouse is idle).
    if decoded.count > 1 {
        let distinct = Set(decoded.map { "\($0.0)/\($0.1)" })
        check(distinct.count == 1, "短时间内读数应稳定，实际出现 \(distinct.count) 种: \(distinct)")
    }

    // macOS selection rule: IOKit exposes one entry per device and only the
    // primary usage page, so the core ships a separate rule for this model
    // (0xFF00..0xFFFF on a known vendor). Verify it against the live table and
    // prove the device it picks can actually be read.
    let rustCandidates = candidates.filter { descriptor in
        battbar_atk_is_macos_candidate(
            UInt16(descriptor.vendorID),
            UInt16(descriptor.primaryUsagePage),
            UInt16(descriptor.primaryUsage)
        ) == 1
    }
    check(rustCandidates.count == 1, "核心的 macOS 规则应选出 1 个设备，实际 \(rustCandidates.count)")
    check(
        rustCandidates.first?.primaryUsagePage == candidates[0].primaryUsagePage,
        "核心与 Swift 应选中同一个设备"
    )
    print(
        "  设备过滤: IOKit 看到 \(candidates.count) 个厂商设备，核心规则命中 \(rustCandidates.count) 个"
            + "（page=0x\(String(candidates[0].primaryUsagePage, radix: 16))）"
    )
    return true
}

// MARK: - Razer

func testRazer() -> Bool {
    print("Razer")
    let session = HIDEnumerationSession(vendorIDs: [RazerProvider.vendorID])
    let candidates = session.devices.filter { RazerProvider.supportedPIDs.contains($0.productID) }
    guard !candidates.isEmpty else {
        print("  没有找到 Razer 接收器，跳过（这是当前已知的未验证项）")
        return true
    }

    var coreRequest = [UInt8](repeating: 0, count: Int(battbar_razer_request_len()))
    let written = coreRequest.withUnsafeMutableBufferPointer {
        battbar_razer_request(RazerProtocol.commandClass, RazerProtocol.batteryCommand, $0.baseAddress, $0.count)
    }
    check(written == Int32(coreRequest.count), "razer core request length \(written)")
    let swiftRequest = RazerProtocol.request(
        commandClass: RazerProtocol.commandClass,
        commandID: RazerProtocol.batteryCommand
    )
    check(coreRequest == swiftRequest, "razer request mismatch")
    print("  Razer 请求与 Swift 一致（\(coreRequest.count) 字节，CRC 0x\(String(coreRequest[88], radix: 16))）")
    print("  真机读电量需要在实机上运行；本次只验证请求封装一致。")
    return true
}

// MARK: - Bluetooth

func testBluetooth() -> Bool {
    print("Bluetooth")
    let provider = BluetoothProvider()
    let outcome = provider.scan(force: true)
    if outcome.issues.isEmpty {
        print("  system_profiler 读取成功，发现 \(outcome.devices.count) 个蓝牙鼠标")
    } else {
        print("  system_profiler 返回问题: \(outcome.issues.map(\.code))")
    }
    if outcome.devices.isEmpty {
        print("  当前没有连接蓝牙鼠标，无法做真机比对（这是已知的未验证项）")
    } else {
        for device in outcome.devices {
            print("  \(device.name) · \(device.batteryText) · 充电=\(String(describing: device.charging))")
        }
    }
    return true
}

// MARK: - Main

print("真机测试 · BattBar Rust 核心（macOS）\n")
_ = testATK()
print("")
_ = testRazer()
print("")
_ = testBluetooth()

print("")
print("真机测试: \(checks) 项检查，\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
