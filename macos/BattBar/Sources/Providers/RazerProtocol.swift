import Foundation

/// Razer 2.4G feature-report protocol.
///
/// A request/response is a 90-byte feature report. Layout (0-based):
///   0 status, 1 transaction id, 2...3 remaining packets, 4 protocol type,
///   5 data size, 6 command class, 7 command id, 8...87 arguments, 88 CRC.
///
/// The CRC is an XOR of bytes 2...87. Battery is `round(argument[1] * 100/255)`.
enum RazerProtocol {
    static let reportLength = 90
    static let transactionID: UInt8 = 0x1F
    static let commandClass: UInt8 = 0x07
    static let batteryCommand: UInt8 = 0x80
    static let chargingCommand: UInt8 = 0x84

    static func request(commandClass: UInt8, commandID: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[1] = transactionID
        report[5] = 0x02
        report[6] = commandClass
        report[7] = commandID
        report[88] = crc(report)
        return report
    }

    static func crc(_ report: [UInt8]) -> UInt8 {
        guard report.count >= 89 else { return 0 }
        var value: UInt8 = 0
        for index in 2..<88 { value ^= report[index] }
        return value
    }

    static func battery(from response: [UInt8]) -> Int? {
        guard response.count >= 10 else { return nil }
        let raw = Int(response[9])
        return max(0, min(100, Int((Double(raw) * 100.0 / 255.0).rounded())))
    }

    static func charging(from response: [UInt8]) -> Bool? {
        guard response.count >= 10 else { return nil }
        return response[9] == 1
    }
}
