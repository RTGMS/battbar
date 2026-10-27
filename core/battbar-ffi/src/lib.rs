//! C ABI for [`battbar_core`].
//!
//! The macOS Swift app links this crate (statically, which keeps the bundle a
//! single binary) and calls it with `@_silgen_name` / a bridging header. The
//! Rust crates never touch the FFI directly, so `battbar-core` stays free of
//! `unsafe`.
//!
//! ## Conventions
//!
//! * Functions returning `int32_t` use the [`status`] values: non-negative is
//!   success (and usually a byte count or a percentage), negative is a
//!   [`status::ERROR_*`] code.
//! * Every pointer argument is checked for null; `out` buffers are checked for
//!   capacity. No function panics across the boundary: the crate is compiled
//!   with `panic = "abort"` in release, and inputs are validated instead.
//! * Buffers are caller owned. Nothing here allocates for the caller.

use std::slice;

use battbar_core::{atk, battery, razer, DecodeError, Reading};

/// Status / return codes shared with the C header.
pub mod status {
    /// The call succeeded.
    pub const OK: i32 = 1;
    /// The report was not one we handle; keep reading.
    pub const NOT_FOR_US: i32 = 0;
    /// A null pointer or a too-small output buffer was passed.
    pub const ERROR_INVALID_ARGUMENT: i32 = -1;
    /// The response was shorter than the protocol requires.
    pub const ERROR_TOO_SHORT: i32 = -2;
    /// The device reported a non-zero status byte.
    pub const ERROR_STATUS: i32 = -3;
    /// The payload could not be interpreted.
    pub const ERROR_MALFORMED: i32 = -4;
}

/// Mirror of [`battbar_core::Reading`] for C callers.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BattbarReading {
    /// Charge percentage, 0...100.
    pub battery: u8,
    /// 1 when charging, 0 otherwise.
    pub charging: u8,
}

fn error_to_status(error: DecodeError) -> i32 {
    match error {
        DecodeError::TooShort => status::ERROR_TOO_SHORT,
        DecodeError::Status(_) => status::ERROR_STATUS,
        DecodeError::NotForUs => status::NOT_FOR_US,
        DecodeError::Malformed(_) => status::ERROR_MALFORMED,
    }
}

fn write_reading(out: *mut BattbarReading, reading: Reading) {
    // SAFETY: the caller guarantees `out` is either null or writable for one
    // `BattbarReading`; null is rejected before this is called.
    unsafe {
        *out = BattbarReading {
            battery: reading.battery,
            charging: u8::from(reading.charging),
        };
    }
}

/// Protocol version of the core, so the Swift side can log it.
#[no_mangle]
pub extern "C" fn battbar_core_version() -> u32 {
    // major << 16 | minor << 8 | patch
    0x00_01_00
}

/// Length of the ATK request buffer, in bytes (17).
#[no_mangle]
pub extern "C" fn battbar_atk_request_len() -> usize {
    atk::REQUEST_LENGTH
}

/// HID report id used by the ATK battery command (0x08).
///
/// Exposed so the platform layer can match the right collection without
/// hard-coding protocol constants.
#[no_mangle]
pub extern "C" fn battbar_atk_report_id() -> u16 {
    u16::from(atk::REPORT_ID)
}

/// Vendor usage page of the ATK control collection (0xFF04).
#[no_mangle]
pub extern "C" fn battbar_atk_vendor_usage_page() -> u16 {
    atk::VENDOR_USAGE_PAGE
}

/// Vendor usage of the ATK control collection (0x02).
#[no_mangle]
pub extern "C" fn battbar_atk_vendor_usage() -> u16 {
    atk::VENDOR_USAGE
}

/// Whether an IOKit-enumerated device should be opened for a battery query.
///
/// macOS sees one entry per device with only the primary usage page, so this
/// uses the vendor-usage-page range instead of the `0xFF04/0x02` collection.
/// Returns 1 for candidates, 0 otherwise.
#[no_mangle]
pub extern "C" fn battbar_atk_is_macos_candidate(
    vendor_id: u16,
    usage_page: u16,
    usage: u16,
) -> u8 {
    let device = battbar_core::HidDeviceInfo {
        vendor_id,
        usage_page: Some(usage_page),
        usage: Some(usage),
        ..Default::default()
    };
    u8::from(atk::is_macos_candidate(&device))
}

/// Fill `out` with the ATK battery request. Returns the number of bytes written
/// or [`status::ERROR_INVALID_ARGUMENT`].
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_atk_request(out: *mut u8, out_len: usize) -> i32 {
    if out.is_null() || out_len < atk::REQUEST_LENGTH {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let request = atk::battery_request();
    // SAFETY: checked above, and the source is a fixed-size array.
    unsafe {
        std::ptr::copy_nonoverlapping(request.as_ptr(), out, atk::REQUEST_LENGTH);
    }
    atk::REQUEST_LENGTH as i32
}

/// Decode an ATK report.
///
/// Returns [`status::OK`] when a reading was written, [`status::NOT_FOR_US`]
/// when the buffer is not an ATK battery report (keep reading), or a negative
/// error code.
///
/// # Safety
/// `bytes` must be valid for reads of `len` bytes; `out` must be writable for
/// one [`BattbarReading`].
#[no_mangle]
pub unsafe extern "C" fn battbar_atk_decode(
    report_id: u8,
    bytes: *const u8,
    len: usize,
    out: *mut BattbarReading,
) -> i32 {
    if bytes.is_null() || out.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees a readable region of `len` bytes.
    let data = unsafe { slice::from_raw_parts(bytes, len) };

    match atk::decode(report_id, data) {
        None => status::NOT_FOR_US,
        Some(Ok(reading)) => {
            write_reading(out, reading);
            status::OK
        }
        Some(Err(error)) => error_to_status(error),
    }
}

/// Length of a Razer feature report, in bytes (90).
#[no_mangle]
pub extern "C" fn battbar_razer_request_len() -> usize {
    razer::REPORT_LENGTH
}

/// Fill `out` with a Razer request for `command_id`
/// (`0x80` battery, `0x84` charging). Returns the byte count or an error.
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_request(
    command_id: u8,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    if out.is_null() || out_len < razer::REPORT_LENGTH {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let request = razer::request(razer::COMMAND_CLASS, command_id);
    // SAFETY: checked above, and the source is a fixed-size array.
    unsafe {
        std::ptr::copy_nonoverlapping(request.as_ptr(), out, razer::REPORT_LENGTH);
    }
    razer::REPORT_LENGTH as i32
}

/// Decode a Razer battery response into `out`.
///
/// A leading report-id byte (91-byte buffer) is handled transparently.
///
/// # Safety
/// `bytes` must be valid for reads of `len` bytes; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_decode_battery(
    bytes: *const u8,
    len: usize,
    out: *mut BattbarReading,
) -> i32 {
    if bytes.is_null() || out.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees a readable region of `len` bytes.
    let data = unsafe { slice::from_raw_parts(bytes, len) };

    match razer::decode_battery(data) {
        Ok(reading) => {
            write_reading(out, reading);
            status::OK
        }
        Err(error) => error_to_status(error),
    }
}

/// Decode a Razer charging response into `out`.
///
/// The battery byte is passed through unchanged so callers can keep showing the
/// last known percentage.
///
/// # Safety
/// `bytes` must be valid for reads of `len` bytes; `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_decode_charging(
    bytes: *const u8,
    len: usize,
    out: *mut BattbarReading,
) -> i32 {
    if bytes.is_null() || out.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees a readable region of `len` bytes.
    let data = unsafe { slice::from_raw_parts(bytes, len) };

    if let Err(error) =
        razer::validate_response(data, razer::COMMAND_CLASS, razer::CHARGING_COMMAND)
    {
        return error_to_status(error);
    }
    match razer::charging(data) {
        Some(charging) => {
            write_reading(
                out,
                Reading {
                    battery: 0,
                    charging,
                },
            );
            status::OK
        }
        None => status::ERROR_TOO_SHORT,
    }
}

/// Parse a percentage out of a string such as `"75%"`.
///
/// Returns `0..=100`, or [`status::ERROR_INVALID_ARGUMENT`] when the string is
/// absent or unparseable. (`0` is a valid reading, so errors are negative.)
///
/// # Safety
/// `text` must be null or a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn battbar_parse_percent(text: *const std::os::raw::c_char) -> i32 {
    if text.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees a NUL-terminated string.
    let borrowed = unsafe { std::ffi::CStr::from_ptr(text) };
    let Ok(value) = borrowed.to_str() else {
        return status::ERROR_INVALID_ARGUMENT;
    };
    match battery::parse_percent_text(value) {
        Some(percent) => i32::from(percent),
        None => status::ERROR_INVALID_ARGUMENT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn atk_request_round_trip() {
        let mut buffer = [0u8; 17];
        // SAFETY: the buffer is exactly the expected size.
        let written = unsafe { battbar_atk_request(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, 17);
        assert_eq!(buffer[0], 0x08);
        assert_eq!(buffer[1], 0x04);
        assert_eq!(buffer[16], 0x49);
    }

    #[test]
    fn rejects_small_buffers() {
        let mut buffer = [0u8; 4];
        // SAFETY: the buffer is deliberately too small; the function must refuse
        // rather than write past the end.
        let written = unsafe { battbar_atk_request(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, status::ERROR_INVALID_ARGUMENT);
    }

    #[test]
    fn rejects_null_pointers() {
        let mut reading = BattbarReading::default();
        // SAFETY: null is explicitly allowed as an invalid input.
        let result = unsafe { battbar_atk_decode(8, std::ptr::null(), 0, &mut reading) };
        assert_eq!(result, status::ERROR_INVALID_ARGUMENT);
    }

    #[test]
    fn atk_decode_statuses() {
        let sample = [
            0x08, 0x04, 0, 0, 0, 0x02, 0x64, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let mut reading = BattbarReading::default();
        // SAFETY: the slice and the out pointer are valid.
        let result = unsafe { battbar_atk_decode(8, sample.as_ptr(), sample.len(), &mut reading) };
        assert_eq!(result, status::OK);
        assert_eq!(reading.battery, 100);
        assert_eq!(reading.charging, 1);

        let status_only = [0x04, 0x01, 0, 0, 0, 50, 0];
        // SAFETY: as above.
        let result =
            unsafe { battbar_atk_decode(8, status_only.as_ptr(), status_only.len(), &mut reading) };
        assert_eq!(result, status::ERROR_STATUS);

        let foreign = [0x09, 0x04, 0, 0, 0, 50, 0];
        // SAFETY: as above.
        let result =
            unsafe { battbar_atk_decode(9, foreign.as_ptr(), foreign.len(), &mut reading) };
        assert_eq!(result, status::NOT_FOR_US);
    }

    #[test]
    fn razer_round_trip() {
        let mut request = [0u8; 90];
        // SAFETY: the buffer matches the report length.
        let written = unsafe {
            battbar_razer_request(razer::BATTERY_COMMAND, request.as_mut_ptr(), request.len())
        };
        assert_eq!(written, 90);
        assert_eq!(request[88], 0x85);

        let mut response = [0u8; 90];
        response[0] = 0x02;
        response[6] = razer::COMMAND_CLASS;
        response[7] = razer::BATTERY_COMMAND;
        response[9] = 128;

        let mut reading = BattbarReading::default();
        // SAFETY: the slice and the out pointer are valid.
        let result = unsafe {
            battbar_razer_decode_battery(response.as_ptr(), response.len(), &mut reading)
        };
        assert_eq!(result, status::OK);
        assert_eq!(reading.battery, 50);

        response[7] = razer::CHARGING_COMMAND;
        response[9] = 1;
        // SAFETY: as above.
        let result = unsafe {
            battbar_razer_decode_charging(response.as_ptr(), response.len(), &mut reading)
        };
        assert_eq!(result, status::OK);
        assert_eq!(reading.charging, 1);
    }

    #[test]
    fn parses_percent_strings() {
        let text = CString::new("75%").unwrap();
        // SAFETY: the CString outlives the call.
        assert_eq!(unsafe { battbar_parse_percent(text.as_ptr()) }, 75);

        let bad = CString::new("abc").unwrap();
        // SAFETY: as above.
        assert_eq!(
            unsafe { battbar_parse_percent(bad.as_ptr()) },
            status::ERROR_INVALID_ARGUMENT
        );
    }
}
