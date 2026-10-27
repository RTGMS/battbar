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
/// The receiver exposes a 16-byte vendor report (report ID `0x08`). The first
/// byte is the command (`0x04` for battery), the last byte is a checksum seeded
/// with the report ID:
///
///     checksum = (0x55 - ((0x08 + sum(bytes[0..14])) & 0xFF)) & 0xFF
///
/// macOS expects the report ID as the first byte of the buffer passed to
/// `IOHIDDeviceSetReport`, hence the 17-byte request buffer.
enum ATKProtocol {
    static let reportID: UInt8 = 0x08
    static let commandBattery: UInt8 = 0x04
    static let packetLength = 17

    static func batteryRequest() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: packetLength)
        packet[0] = reportID
        packet[1] = commandBattery
        var checksum = 0
        for index in 0..<(packetLength - 1) {
            checksum += Int(packet[index])
        }
        packet[packetLength - 1] = UInt8((0x55 - (checksum & 0xff)) & 0xff)
        return packet
    }

    static func decode(reportID: Int, bytes: [UInt8]) -> Result<ATKReading, ATKDecodeError>? {
        var payload = bytes
        if payload.first == self.reportID {
            payload.removeFirst()
        } else if reportID != Int(self.reportID) {
            return nil
        }
        guard payload.count >= 7, payload[0] == commandBattery else { return nil }
        let status = payload[1]
        guard status == 0 else { return .failure(.invalidStatus(status)) }
        return .success(ATKReading(
            battery: normalizedBattery(Int(payload[5])),
            charging: payload[6] == 1
        ))
    }
}
