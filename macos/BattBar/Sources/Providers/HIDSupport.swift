import Foundation
import IOKit.hid

struct HIDDeviceDescriptor {
    let device: IOHIDDevice
    let vendorID: Int
    let productID: Int
    let product: String
    let manufacturer: String
    let serialNumber: String
    let primaryUsagePage: Int
    let primaryUsage: Int
    let transport: String
    let maxFeatureReportSize: Int
}

final class HIDEnumerationSession {
    private let manager: IOHIDManager
    private(set) var devices: [HIDDeviceDescriptor] = []
    private let runLoop: CFRunLoop

    init(vendorIDs: [Int]) {
        runLoop = CFRunLoopGetCurrent()
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = vendorIDs.map { [kIOHIDVendorIDKey as String: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess,
           ProcessInfo.processInfo.environment["BATTBAR_DEBUG"] == "1" {
            // Enumeration still works without a manager-level open on macOS.
            print("[HID] manager open returned \(result)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        devices = Self.copyDevices(from: manager)
    }

    deinit {
        close()
    }

    func close() {
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private static func copyDevices(from manager: IOHIDManager) -> [HIDDeviceDescriptor] {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.compactMap { device in
            func intProperty(_ key: String) -> Int? {
                (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
            }
            func stringProperty(_ key: String) -> String {
                (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
            }
            guard let vendor = intProperty(kIOHIDVendorIDKey),
                  let productID = intProperty(kIOHIDProductIDKey) else { return nil }
            return HIDDeviceDescriptor(
                device: device,
                vendorID: vendor,
                productID: productID,
                product: stringProperty(kIOHIDProductKey),
                manufacturer: stringProperty(kIOHIDManufacturerKey),
                serialNumber: stringProperty(kIOHIDSerialNumberKey),
                primaryUsagePage: intProperty(kIOHIDPrimaryUsagePageKey) ?? -1,
                primaryUsage: intProperty(kIOHIDPrimaryUsageKey) ?? -1,
                transport: stringProperty(kIOHIDTransportKey),
                maxFeatureReportSize: intProperty(kIOHIDMaxFeatureReportSizeKey) ?? 0
            )
        }
        .sorted {
            if $0.primaryUsagePage != $1.primaryUsagePage {
                return $0.primaryUsagePage > $1.primaryUsagePage
            }
            return $0.product < $1.product
        }
    }
}

enum HIDError: LocalizedError {
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    case timeout
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "无法打开 HID 设备（0x\(String(code, radix: 16))）"
        case .writeFailed(let code): return "HID 写入失败（0x\(String(code, radix: 16))）"
        case .readFailed(let code): return "HID 读取失败（0x\(String(code, radix: 16))）"
        case .timeout: return "HID 读取超时"
        case .invalidResponse(let message): return message
        }
    }
}

func hidString(_ device: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
}

func hidInt(_ device: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
}
