import Foundation

struct ATKReading: Equatable {
    let battery: Int
    let charging: Bool
}

enum ATKDecodeError: Error, Equatable {
    case invalidStatus(UInt8)
}

/// ATK / Compx 2.4G receiver protocol.
///
/// The encoding/decoding lives in the Rust core (`core/battbar-core`) and is
/// reached through the C ABI declared in
/// `core/battbar-ffi/include/battbar_core.h`. This type is a thin typed wrapper
/// so the rest of the app keeps working with Swift values.
///
/// The receiver exposes a 16-byte vendor report (report ID `0x08`). Byte 0 is
/// the command (`0x04` for battery), the last byte is a checksum seeded with the
/// report ID:
///
///     checksum = (0x55 - ((0x08 + sum(bytes[0..14])) & 0xFF)) & 0xFF
///
/// macOS expects the report ID as the first byte of the buffer passed to
/// `IOHIDDeviceSetReport`, hence the 17-byte request buffer.
enum ATKProtocol {
    /// HID report ID, sourced from the core so there is a single definition.
    static var reportID: UInt8 { UInt8(battbar_atk_report_id()) }
    static let commandBattery: UInt8 = 0x04
    /// Request length including the report ID (17).
    static var packetLength: Int { Int(battbar_atk_request_len()) }

    static func batteryRequest() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: packetLength)
        let written = packet.withUnsafeMutableBufferPointer {
            battbar_atk_request($0.baseAddress, $0.count)
        }
        precondition(written == packet.count, "battbar_atk_request returned \(written)")
        return packet
    }

    /// Decode a report read from the receiver.
    ///
    /// Returns `nil` when the buffer is not an ATK battery report (keep
    /// reading), and `.failure` when the device reported an error status.
    static func decode(reportID: Int, bytes: [UInt8]) -> Result<ATKReading, ATKDecodeError>? {
        var reading = BattbarReading(battery: 0, charging: 0)
        var deviceStatus: UInt8 = 0
        let result = bytes.withUnsafeBufferPointer {
            battbar_atk_decode(
                UInt8(truncatingIfNeeded: reportID),
                $0.baseAddress,
                $0.count,
                &reading,
                &deviceStatus
            )
        }
        switch result {
        case statusOK:
            return .success(ATKReading(battery: Int(reading.battery), charging: reading.charging == 1))
        case statusNotForUs:
            return nil
        case statusDeviceError:
            return .failure(.invalidStatus(deviceStatus))
        default:
            // Too short or malformed: not a usable report, keep waiting.
            return nil
        }
    }
}

// Mirrors of the status codes in battbar_core.h (C macros do not import into
// Swift). Kept in sync with `core/battbar-ffi/src/lib.rs`.
let statusOK: Int32 = 1
let statusNotForUs: Int32 = 0
let statusDeviceError: Int32 = -3
