import Foundation

/// Razer 2.4G feature-report protocol.
///
/// The encoding/decoding lives in the Rust core (`core/battbar-core`); this is a
/// thin typed wrapper over the C ABI.
///
/// A request/response is a 90-byte feature report. Layout (0-based):
///   0 status, 1 transaction id, 2...3 remaining packets, 4 protocol type,
///   5 data size, 6 command class, 7 command id, 8...87 arguments, 88 CRC.
///
/// The CRC is an XOR of bytes 2...87. Battery is `round(argument[1] * 100/255)`.
enum RazerProtocol {
    /// Report length, sourced from the core.
    static var reportLength: Int { Int(battbar_razer_request_len()) }
    static let transactionID: UInt8 = 0x1F
    static let commandClass: UInt8 = 0x07
    static let batteryCommand: UInt8 = 0x80
    static let chargingCommand: UInt8 = 0x84

    static func request(commandClass: UInt8, commandID: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        let written = report.withUnsafeMutableBufferPointer {
            battbar_razer_request(commandClass, commandID, $0.baseAddress, $0.count)
        }
        precondition(written == report.count, "battbar_razer_request returned \(written)")
        return report
    }

    /// CRC of a report (XOR of bytes 2...87).
    ///
    /// Kept in Swift on purpose: the tests compare it against the byte the core
    /// writes, which cross-checks the two implementations.
    static func crc(_ report: [UInt8]) -> UInt8 {
        guard report.count >= 89 else { return 0 }
        var value: UInt8 = 0
        for index in 2..<88 { value ^= report[index] }
        return value
    }

    static func battery(from response: [UInt8]) -> Int? {
        var reading = BattbarReading(battery: 0, charging: 0)
        let result = response.withUnsafeBufferPointer {
            battbar_razer_decode_battery($0.baseAddress, $0.count, &reading)
        }
        return result == statusOK ? Int(reading.battery) : nil
    }

    static func charging(from response: [UInt8]) -> Bool? {
        var reading = BattbarReading(battery: 0, charging: 0)
        let result = response.withUnsafeBufferPointer {
            battbar_razer_decode_charging($0.baseAddress, $0.count, &reading)
        }
        return result == statusOK ? reading.charging == 1 : nil
    }
}
