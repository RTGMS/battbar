// Smoke test for the Rust core's C ABI, compiled and run by
// core/scripts/build-macos.sh. It only proves that the static library links and
// behaves as documented; the full coverage lives in `cargo test`.
//
// The C header is imported through `-import-objc-header`, which is exactly how
// the SwiftUI app would consume it.

import Foundation

// The C status macros are not imported into Swift, so they are restated here
// and kept in sync with core/battbar-ffi/include/battbar_core.h.
let statusOK: Int32 = 1
let statusNotForUs: Int32 = 0
let statusInvalidArgument: Int32 = -1

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition { return }
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

// Version must be non-zero so the app can log it.
check(battbar_core_version() != 0, "core version is reported")

// ATK request: 17 bytes, report id 0x08, command 0x04, checksum 0x49.
var request = [UInt8](repeating: 0, count: Int(battbar_atk_request_len()))
let written = request.withUnsafeMutableBufferPointer { buffer in
    battbar_atk_request(buffer.baseAddress, buffer.count)
}
check(written == 17, "atk request length, got \(written)")
check(request[0] == 0x08, "atk report id, got \(request[0])")
check(request[1] == 0x04, "atk command, got \(request[1])")
check(request[16] == 0x49, "atk checksum, got \(request[16])")

// Refuse a buffer that is too small instead of overflowing it.
var tiny = [UInt8](repeating: 0, count: 4)
let refused = tiny.withUnsafeMutableBufferPointer { buffer in
    battbar_atk_request(buffer.baseAddress, buffer.count)
}
check(refused == statusInvalidArgument, "atk request must refuse a short buffer, got \(refused)")

// ATK decode of a real-shaped report.
let sample: [UInt8] = [0x08, 0x04, 0, 0, 0, 0x02, 0x64, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0]
var reading = BattbarReading(battery: 0, charging: 0)
let decoded = sample.withUnsafeBufferPointer { buffer in
    battbar_atk_decode(0x08, buffer.baseAddress, buffer.count, &reading)
}
check(decoded == statusOK, "atk decode status, got \(decoded)")
check(reading.battery == 100, "atk battery, got \(reading.battery)")
check(reading.charging == 1, "atk charging, got \(reading.charging)")

// A foreign report must be ignored, not treated as an error.
let foreign: [UInt8] = [0x09, 0x04, 0, 0, 0, 50, 0]
let ignored = foreign.withUnsafeBufferPointer { buffer in
    battbar_atk_decode(0x09, buffer.baseAddress, buffer.count, &reading)
}
check(ignored == statusNotForUs, "atk foreign report, got \(ignored)")

// Razer request: 90 bytes with CRC 0x85 for the battery command.
var razer = [UInt8](repeating: 0, count: Int(battbar_razer_request_len()))
let razerLength = razer.withUnsafeMutableBufferPointer { buffer in
    battbar_razer_request(0x80, buffer.baseAddress, buffer.count)
}
check(razerLength == 90, "razer request length, got \(razerLength)")
check(razer[88] == 0x85, "razer crc, got \(razer[88])")

// Razer response with battery argument 128 -> 50%.
var response = [UInt8](repeating: 0, count: 90)
response[0] = 0x02
response[6] = 0x07
response[7] = 0x80
response[9] = 128
let razerStatus = response.withUnsafeBufferPointer { buffer in
    battbar_razer_decode_battery(buffer.baseAddress, buffer.count, &reading)
}
check(razerStatus == statusOK, "razer decode status, got \(razerStatus)")
check(reading.battery == 50, "razer battery, got \(reading.battery)")

// Percentage helper.
let percent = "75%".withCString { battbar_parse_percent($0) }
check(percent == 75, "parse percent, got \(percent)")
let badPercent = "abc".withCString { battbar_parse_percent($0) }
check(badPercent == statusInvalidArgument, "parse percent must reject junk, got \(badPercent)")

if failures == 0 {
    print("ffi smoke test: ok")
} else {
    fputs("ffi smoke test: \(failures) failure(s)\n", stderr)
    exit(1)
}
