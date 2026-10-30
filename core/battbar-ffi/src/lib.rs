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
    out_status: *mut u8,
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
        Some(Err(error)) => {
            // Mirror the device status byte for callers that surface it.
            if !out_status.is_null() {
                if let DecodeError::Status(value) = &error {
                    // SAFETY: non-null and the caller provided one byte.
                    unsafe { *out_status = *value };
                }
            }
            error_to_status(error)
        }
    }
}

/// Length of a Razer feature report, in bytes (90).
#[no_mangle]
pub extern "C" fn battbar_razer_request_len() -> usize {
    razer::REPORT_LENGTH
}

/// Fill `out` with a Razer request for `command_class` / `command_id`
/// (`0x07`/`0x80` battery, `0x07`/`0x84` charging). Returns the byte count or
/// an error.
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_request(
    command_class: u8,
    command_id: u8,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    if out.is_null() || out_len < razer::REPORT_LENGTH {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let request = razer::request(command_class, command_id);
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

// ---- HID enumeration ---------------------------------------------------

/// One HID collection as the platform layer enumerated it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct BattbarHidInfo {
    /// Device path (NUL-terminated).
    pub path: *const std::os::raw::c_char,
    pub vendor_id: u16,
    pub product_id: u16,
    /// Product string, or null.
    pub product: *const std::os::raw::c_char,
    /// Serial number, or null.
    pub serial_number: *const std::os::raw::c_char,
    /// Interface number, or -1 when the OS does not report one.
    pub interface: i32,
    /// Usage page, or -1 when unknown.
    pub usage_page: i32,
    /// Usage, or -1 when unknown.
    pub usage: i32,
}

fn hid_info_from(entry: &BattbarHidInfo) -> battbar_core::HidDeviceInfo {
    // SAFETY: the caller guarantees valid strings or null.
    let path = unsafe { c_str_or_empty(entry.path) }.to_string();
    let product = unsafe { c_str_or_empty(entry.product) };
    let serial = unsafe { c_str_or_empty(entry.serial_number) };
    battbar_core::HidDeviceInfo {
        path,
        vendor_id: entry.vendor_id,
        product_id: entry.product_id,
        product: (!product.is_empty()).then(|| product.to_string()),
        serial_number: (!serial.is_empty()).then(|| serial.to_string()),
        interface: (entry.interface >= 0).then_some(entry.interface),
        usage_page: (entry.usage_page >= 0).then_some(entry.usage_page as u16),
        usage: (entry.usage >= 0).then_some(entry.usage as u16),
    }
}

/// Select the ATK receivers worth probing.
///
/// Takes the per-collection list the platform enumerated (the hidapi shape) and
/// returns indices into it, so the caller keeps ownership of its own data.
///
/// # Safety
/// `devices` must hold `count` entries; `out_indices` `capacity` slots.
#[no_mangle]
pub unsafe extern "C" fn battbar_atk_select(
    devices: *const BattbarHidInfo,
    count: i32,
    out_indices: *mut i32,
    capacity: i32,
    out_count: *mut i32,
) -> i32 {
    unsafe { select(devices, count, out_indices, capacity, out_count, false) }
}

/// Select the Razer receivers worth probing. Same contract as
/// [`battbar_atk_select`].
///
/// # Safety
/// Same as [`battbar_atk_select`].
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_select(
    devices: *const BattbarHidInfo,
    count: i32,
    out_indices: *mut i32,
    capacity: i32,
    out_count: *mut i32,
) -> i32 {
    unsafe { select(devices, count, out_indices, capacity, out_count, true) }
}

unsafe fn select(
    devices: *const BattbarHidInfo,
    count: i32,
    out_indices: *mut i32,
    capacity: i32,
    out_count: *mut i32,
    razer: bool,
) -> i32 {
    if count < 0 || capacity < 0 || out_indices.is_null() || out_count.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    if count > 0 && devices.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }

    let mut owned = Vec::with_capacity(count as usize);
    for index in 0..count as usize {
        // SAFETY: the caller guarantees `count` readable entries.
        owned.push(hid_info_from(unsafe { &*devices.add(index) }));
    }

    let picked: Vec<usize> = if razer {
        owned
            .iter()
            .enumerate()
            .filter(|(_, device)| battbar_core::razer::is_candidate(device))
            .map(|(index, _)| index)
            .collect()
    } else {
        // The core returns references; map them back to indices.
        battbar_core::atk::find_candidates(&owned)
            .into_iter()
            .filter_map(|candidate| {
                owned
                    .iter()
                    .position(|device| std::ptr::eq(device, candidate))
            })
            .collect()
    };

    let written = picked.len().min(capacity as usize);
    // SAFETY: the caller provides `capacity` writable slots.
    let out = unsafe { std::slice::from_raw_parts_mut(out_indices, written) };
    for (slot, index) in out.iter_mut().zip(picked.iter()) {
        *slot = *index as i32;
    }
    // SAFETY: validated non-null above.
    unsafe { *out_count = written as i32 };
    0
}

// ---- Scan merge --------------------------------------------------------

/// One device as the merge policy sees it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct BattbarDeviceSummary {
    /// Stable device id (NUL-terminated).
    pub id: *const std::os::raw::c_char,
    /// Display name (NUL-terminated); used for ordering.
    pub name: *const std::os::raw::c_char,
    /// 0 ATK, 1 Razer, 2 Bluetooth.
    pub provider: i32,
    /// 0 receiver, 1 Bluetooth.
    pub connection: i32,
}

/// Where a merged entry came from.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct BattbarMergedDevice {
    /// 0 = taken from `fresh`, 1 = retained from `previous`.
    pub from_previous: u8,
    /// Index into that slice.
    pub index: i32,
    /// 1 when the reading is retained from an earlier scan.
    pub stale: u8,
}

/// Merge a scan with the previous result and pick the active device.
///
/// `out_entries` must have room for `fresh_count + previous_count` entries;
/// `out_count` and `out_active` receive the entry count and the index of the
/// active device (`-1` when there is none). An unknown provider or connection
/// code returns [`status::ERROR_INVALID_ARGUMENT`] rather than silently
/// reordering the entries. Returns 0 or an error code.
///
/// # Safety
/// All slices must be valid for their advertised lengths.
#[no_mangle]
pub unsafe extern "C" fn battbar_merge_scan(
    fresh: *const BattbarDeviceSummary,
    fresh_count: i32,
    previous: *const BattbarDeviceSummary,
    previous_count: i32,
    failed_providers: *const i32,
    failed_count: i32,
    selected_id: *const std::os::raw::c_char,
    out_entries: *mut BattbarMergedDevice,
    out_count: *mut i32,
    out_active: *mut i32,
) -> i32 {
    if fresh_count < 0 || previous_count < 0 || failed_count < 0 {
        return status::ERROR_INVALID_ARGUMENT;
    }
    if out_entries.is_null() || out_count.is_null() || out_active.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }
    if (fresh_count > 0 && fresh.is_null()) || (previous_count > 0 && previous.is_null()) {
        return status::ERROR_INVALID_ARGUMENT;
    }
    if failed_count > 0 && failed_providers.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }

    // Collect the borrowed summaries; the C strings stay owned by the caller.
    let mut fresh_ids: Vec<String> = Vec::new();
    let mut previous_ids: Vec<String> = Vec::new();
    let mut fresh_names: Vec<String> = Vec::new();
    let mut previous_names: Vec<String> = Vec::new();

    let collect = |entries: *const BattbarDeviceSummary,
                   count: i32,
                   ids: &mut Vec<String>,
                   names: &mut Vec<String>|
     -> Vec<(i32, i32)> {
        let mut kinds = Vec::new();
        for index in 0..count as usize {
            // SAFETY: the caller guarantees `count` readable entries.
            let entry = unsafe { &*entries.add(index) };
            ids.push(unsafe { c_str_or_empty(entry.id) }.to_string());
            names.push(unsafe { c_str_or_empty(entry.name) }.to_string());
            kinds.push((entry.provider, entry.connection));
        }
        kinds
    };

    let fresh_kinds = collect(fresh, fresh_count, &mut fresh_ids, &mut fresh_names);
    let previous_kinds = collect(
        previous,
        previous_count,
        &mut previous_ids,
        &mut previous_names,
    );

    // An unknown code would drop its entry when the summaries are built, and
    // the entries after it would shift onto the wrong device, so refuse the
    // whole scan instead of returning indices the caller cannot trust.
    if fresh_kinds
        .iter()
        .chain(previous_kinds.iter())
        .any(|(provider, connection)| {
            battbar_core::merge::Provider::from_code(*provider).is_none()
                || battbar_core::merge::Connection::from_code(*connection).is_none()
        })
    {
        return status::ERROR_INVALID_ARGUMENT;
    }

    let fresh_summaries = to_summaries(&fresh_ids, &fresh_names, &fresh_kinds);
    let previous_summaries = to_summaries(&previous_ids, &previous_names, &previous_kinds);

    let mut failed: Vec<battbar_core::merge::Provider> = Vec::new();
    for index in 0..failed_count as usize {
        // SAFETY: the caller guarantees `failed_count` readable entries.
        if let Some(provider) =
            battbar_core::merge::Provider::from_code(unsafe { *failed_providers.add(index) })
        {
            failed.push(provider);
        }
    }

    let selected = unsafe { c_str_or_empty(selected_id) };
    let selected = if selected.is_empty() {
        None
    } else {
        Some(selected)
    };

    let (merged, active) =
        battbar_core::merge::merge_scan(&fresh_summaries, &previous_summaries, &failed, selected);

    // SAFETY: the caller promises room for fresh_count + previous_count entries.
    let out = unsafe {
        std::slice::from_raw_parts_mut(out_entries, (fresh_count + previous_count) as usize)
    };
    for (slot, entry) in out.iter_mut().zip(merged.iter()) {
        *slot = BattbarMergedDevice {
            from_previous: u8::from(entry.from_previous),
            index: entry.index as i32,
            stale: u8::from(entry.stale),
        };
    }
    // SAFETY: validated non-null above.
    unsafe {
        *out_count = merged.len() as i32;
        *out_active = active.map_or(-1, |index| index as i32);
    }
    0
}

/// Write `text` into a NUL-terminated UTF-8 buffer.
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
unsafe fn write_string(text: &str, out: *mut std::os::raw::c_char, out_len: usize) -> i32 {
    if out.is_null() || out_len == 0 {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let bytes = text.as_bytes();
    if bytes.len() + 1 > out_len {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: length checked above.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), bytes.len());
        *out.add(bytes.len()) = 0;
    }
    bytes.len() as i32
}

/// Human-facing name and subtitle for an ATK product string.
///
/// # Safety
/// Output buffers must be valid for their advertised lengths.
#[no_mangle]
pub unsafe extern "C" fn battbar_atk_display_name(
    product: *const std::os::raw::c_char,
    out_name: *mut std::os::raw::c_char,
    name_len: usize,
    out_subtitle: *mut std::os::raw::c_char,
    subtitle_len: usize,
) -> i32 {
    let product = unsafe { c_str_or_empty(product) };
    let display = atk::make_display_name(product);
    let written = unsafe { write_string(&display.name, out_name, name_len) };
    if written < 0 {
        return written;
    }
    unsafe { write_string(&display.subtitle, out_subtitle, subtitle_len) }
}

/// Stable id for an ATK receiver.
///
/// # Safety
/// Output buffer must be valid for `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_atk_device_id(
    vendor_id: u16,
    product_id: u16,
    serial_number: *const std::os::raw::c_char,
    product: *const std::os::raw::c_char,
    out: *mut std::os::raw::c_char,
    out_len: usize,
) -> i32 {
    let serial = unsafe { c_str_or_empty(serial_number) };
    let product = unsafe { c_str_or_empty(product) };
    let device = battbar_core::HidDeviceInfo {
        vendor_id,
        product_id,
        serial_number: (!serial.is_empty()).then(|| serial.to_string()),
        product: (!product.is_empty()).then(|| product.to_string()),
        ..Default::default()
    };
    let id = atk::stable_device_id(&device);
    unsafe { write_string(&id, out, out_len) }
}

/// Human-facing name and subtitle for a Razer product string.
///
/// # Safety
/// Output buffers must be valid for their advertised lengths.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_display_name(
    product: *const std::os::raw::c_char,
    product_id: u16,
    out_name: *mut std::os::raw::c_char,
    name_len: usize,
    out_subtitle: *mut std::os::raw::c_char,
    subtitle_len: usize,
) -> i32 {
    let product = unsafe { c_str_or_empty(product) };
    let display = razer::make_display_name(product, product_id);
    let written = unsafe { write_string(&display.name, out_name, name_len) };
    if written < 0 {
        return written;
    }
    unsafe { write_string(&display.subtitle, out_subtitle, subtitle_len) }
}

/// Stable id for a Razer receiver.
///
/// # Safety
/// Output buffer must be valid for `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_razer_device_id(
    vendor_id: u16,
    product_id: u16,
    out: *mut std::os::raw::c_char,
    out_len: usize,
) -> i32 {
    let device = battbar_core::HidDeviceInfo {
        vendor_id,
        product_id,
        ..Default::default()
    };
    let id = razer::stable_device_id(&device);
    unsafe { write_string(&id, out, out_len) }
}

// ---- Bluetooth ---------------------------------------------------------

/// Read a battery percentage out of a flattened macOS attribute list.
///
/// `keys` and `values` are parallel arrays of `count` NUL-terminated UTF-8
/// strings. Returns `0..=100`, or [`status::ERROR_INVALID_ARGUMENT`] when no
/// usable battery attribute is present.
///
/// # Safety
/// Both arrays must contain `count` valid C strings (or be null when `count`
/// is 0).
#[no_mangle]
pub unsafe extern "C" fn battbar_bluetooth_battery(
    count: i32,
    keys: *const *const std::os::raw::c_char,
    values: *const *const std::os::raw::c_char,
) -> i32 {
    let Some(pairs) = (unsafe { collect_pairs(count, keys, values) }) else {
        return status::ERROR_INVALID_ARGUMENT;
    };
    match battbar_core::bluetooth::battery_from_attributes(&pairs) {
        Some(percent) => i32::from(percent),
        None => status::ERROR_INVALID_ARGUMENT,
    }
}

/// Read the charging flag out of a flattened macOS attribute list.
///
/// Returns `1` (charging), `0` (not charging) or
/// [`status::ERROR_INVALID_ARGUMENT`] when the device does not say.
///
/// # Safety
/// Same contract as [`battbar_bluetooth_battery`].
#[no_mangle]
pub unsafe extern "C" fn battbar_bluetooth_charging(
    count: i32,
    keys: *const *const std::os::raw::c_char,
    values: *const *const std::os::raw::c_char,
) -> i32 {
    let Some(pairs) = (unsafe { collect_pairs(count, keys, values) }) else {
        return status::ERROR_INVALID_ARGUMENT;
    };
    match battbar_core::bluetooth::charging_from_attributes(&pairs) {
        Some(true) => 1,
        Some(false) => 0,
        None => status::ERROR_INVALID_ARGUMENT,
    }
}

/// Whether a device name / minor type pair looks like a mouse.
///
/// # Safety
/// Both pointers must be null or valid NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn battbar_bluetooth_is_likely_mouse(
    name: *const std::os::raw::c_char,
    minor_type: *const std::os::raw::c_char,
) -> u8 {
    let name = unsafe { c_str_or_empty(name) };
    let minor = unsafe { c_str_or_empty(minor_type) };
    u8::from(battbar_core::bluetooth::is_likely_mouse(name, minor))
}

/// Write the stable id for a macOS Bluetooth device into `out`.
///
/// Returns the number of bytes written (excluding the NUL) or
/// [`status::ERROR_INVALID_ARGUMENT`] when the buffer is too small.
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_bluetooth_macos_id(
    address: *const std::os::raw::c_char,
    name: *const std::os::raw::c_char,
    out: *mut std::os::raw::c_char,
    out_len: usize,
) -> i32 {
    if out.is_null() || out_len == 0 {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let address = unsafe { c_str_or_empty(address) };
    let name = unsafe { c_str_or_empty(name) };
    let id = battbar_core::bluetooth::macos_device_id(address, name);
    let bytes = id.as_bytes();
    if bytes.len() + 1 > out_len {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees `out_len` writable bytes and the length was
    // checked above.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), bytes.len());
        *out.add(bytes.len()) = 0;
    }
    bytes.len() as i32
}

// ---- Low battery alerts ------------------------------------------------

/// Opaque state for [`battbar_alerts_evaluate`]; create with
/// [`battbar_alerts_new`] and release with [`battbar_alerts_free`].
pub struct BattbarAlertManager {
    inner: std::sync::Mutex<battbar_core::alerts::AlertManager>,
}

/// One device as far as alerting is concerned.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct BattbarAlertDevice {
    /// Stable device id (NUL-terminated).
    pub id: *const std::os::raw::c_char,
    /// Battery percentage, or a negative value when unknown.
    pub battery: i32,
    /// 1 charging, 0 not charging, negative unknown.
    pub charging: i32,
    /// Non-zero when the reading is a retained stale value.
    pub stale: u8,
}

/// Create an alert manager. Returns null on allocation failure.
#[no_mangle]
pub extern "C" fn battbar_alerts_new() -> *mut BattbarAlertManager {
    let manager = Box::new(BattbarAlertManager {
        inner: std::sync::Mutex::new(battbar_core::alerts::AlertManager::new()),
    });
    Box::into_raw(manager)
}

/// Release an alert manager created by [`battbar_alerts_new`].
///
/// # Safety
/// `manager` must come from [`battbar_alerts_new`] and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn battbar_alerts_free(manager: *mut BattbarAlertManager) {
    if manager.is_null() {
        return;
    }
    // SAFETY: owned pointer from battbar_alerts_new, dropped once here.
    drop(unsafe { Box::from_raw(manager) });
}

/// Evaluate one scan result.
///
/// `out_kinds` receives one byte per device: `0` no alert, `1` low, `2`
/// critical. Returns 0 on success or [`status::ERROR_INVALID_ARGUMENT`].
///
/// # Safety
/// `manager` must be valid; `devices` and `out_kinds` must be valid for
/// `count` elements.
#[no_mangle]
pub unsafe extern "C" fn battbar_alerts_evaluate(
    manager: *mut BattbarAlertManager,
    devices: *const BattbarAlertDevice,
    count: i32,
    enabled: u8,
    out_kinds: *mut u8,
) -> i32 {
    if manager.is_null() || out_kinds.is_null() || count < 0 {
        return status::ERROR_INVALID_ARGUMENT;
    }
    if count > 0 && devices.is_null() {
        return status::ERROR_INVALID_ARGUMENT;
    }

    // Collect the ids first so the borrowed slices live long enough.
    let mut ids: Vec<String> = Vec::with_capacity(count as usize);
    let mut inputs: Vec<(Option<u8>, Option<bool>, bool)> = Vec::with_capacity(count as usize);
    for index in 0..count as usize {
        // SAFETY: the caller guarantees `count` readable entries.
        let entry = unsafe { &*devices.add(index) };
        ids.push(unsafe { c_str_or_empty(entry.id) }.to_string());
        inputs.push((
            u8::try_from(entry.battery).ok(),
            match entry.charging {
                1 => Some(true),
                0 => Some(false),
                _ => None,
            },
            entry.stale != 0,
        ));
    }

    let alert_devices: Vec<battbar_core::alerts::AlertDevice<'_>> = ids
        .iter()
        .zip(inputs.iter())
        .map(
            |(id, (battery, charging, stale))| battbar_core::alerts::AlertDevice {
                id: id.as_str(),
                battery: *battery,
                charging: *charging,
                stale: *stale,
            },
        )
        .collect();

    // SAFETY: validated as non-null above.
    let state = unsafe { &*manager };
    let Ok(mut guard) = state.inner.lock() else {
        // A poisoned lock means a previous panic; treat it as unusable.
        return status::ERROR_INVALID_ARGUMENT;
    };
    let events = guard.evaluate(&alert_devices, enabled != 0);

    // Map back to per-device kinds.
    // SAFETY: the caller provides `count` writable bytes.
    unsafe { std::slice::from_raw_parts_mut(out_kinds, count as usize) }.fill(0);
    for event in events {
        if let Some(position) = ids.iter().position(|id| id == event.device_id) {
            let kind = match event.kind {
                battbar_core::alerts::AlertKind::Low => 1u8,
                battbar_core::alerts::AlertKind::Critical => 2u8,
            };
            // SAFETY: position is within `count`.
            unsafe { *out_kinds.add(position) = kind };
        }
    }
    0
}

/// Pair ids/names with their provider/connection codes for the merge policy.
///
/// The codes are already validated by the caller, so nothing is dropped here.
fn to_summaries<'a>(
    ids: &'a [String],
    names: &'a [String],
    kinds: &'a [(i32, i32)],
) -> Vec<battbar_core::merge::DeviceSummary<'a>> {
    ids.iter()
        .zip(names.iter())
        .zip(kinds.iter())
        .filter_map(|((id, name), (provider, connection))| {
            Some(battbar_core::merge::DeviceSummary {
                id: id.as_str(),
                name: name.as_str(),
                provider: battbar_core::merge::Provider::from_code(*provider)?,
                connection: battbar_core::merge::Connection::from_code(*connection)?,
            })
        })
        .collect()
}

/// Write the stable id for a Windows PnP device into `out`.
///
/// Returns the number of bytes written (excluding the NUL) or
/// [`status::ERROR_INVALID_ARGUMENT`] when the buffer is too small.
///
/// # Safety
/// `out` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn battbar_bluetooth_windows_id(
    instance_id: *const std::os::raw::c_char,
    name: *const std::os::raw::c_char,
    out: *mut std::os::raw::c_char,
    out_len: usize,
) -> i32 {
    if out.is_null() || out_len == 0 {
        return status::ERROR_INVALID_ARGUMENT;
    }
    let instance = unsafe { c_str_or_empty(instance_id) };
    let name = unsafe { c_str_or_empty(name) };
    let id = battbar_core::bluetooth::windows_device_id(if instance.is_empty() {
        name
    } else {
        instance
    });
    let bytes = id.as_bytes();
    if bytes.len() + 1 > out_len {
        return status::ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: length checked above.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), bytes.len());
        *out.add(bytes.len()) = 0;
    }
    bytes.len() as i32
}

/// Collect parallel key/value arrays into borrowed pairs.
///
/// # Safety
/// Caller guarantees both arrays hold `count` valid strings.
#[allow(clippy::needless_lifetimes)]
unsafe fn collect_pairs<'a>(
    count: i32,
    keys: *const *const std::os::raw::c_char,
    values: *const *const std::os::raw::c_char,
) -> Option<Vec<(&'a str, &'a str)>> {
    if count < 0 || (count > 0 && (keys.is_null() || values.is_null())) {
        return None;
    }
    let count = count as usize;
    let mut pairs = Vec::with_capacity(count);
    for index in 0..count {
        // SAFETY: caller guarantees `count` readable pointers.
        let key = unsafe { c_str_or_empty(*keys.add(index)) };
        let value = unsafe { c_str_or_empty(*values.add(index)) };
        pairs.push((key, value));
    }
    Some(pairs)
}

/// # Safety
/// `pointer` must be null or a valid NUL-terminated UTF-8 string.
unsafe fn c_str_or_empty<'a>(pointer: *const std::os::raw::c_char) -> &'a str {
    if pointer.is_null() {
        return "";
    }
    // SAFETY: the caller guarantees a NUL-terminated string.
    unsafe { std::ffi::CStr::from_ptr(pointer) }
        .to_str()
        .unwrap_or("")
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

/// Delay in milliseconds before the single retry of a dropped scan, or `-1`
/// when the next scheduled poll should be the only remaining attempt.
///
/// `has_stale` and `already_retried` are booleans: non-zero means true.
#[no_mangle]
pub extern "C" fn battbar_retry_delay_ms(has_stale: u8, already_retried: u8) -> i32 {
    match battbar_core::retry::retry_delay_ms(has_stale != 0, already_retried != 0) {
        Some(delay) => delay as i32,
        None => -1,
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
        let result = unsafe {
            battbar_atk_decode(8, std::ptr::null(), 0, &mut reading, std::ptr::null_mut())
        };
        assert_eq!(result, status::ERROR_INVALID_ARGUMENT);
    }

    #[test]
    fn atk_decode_statuses() {
        let sample = [
            0x08, 0x04, 0, 0, 0, 0x02, 0x64, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let mut reading = BattbarReading::default();
        let mut device_status = 0u8;
        // SAFETY: the slice and the out pointer are valid.
        let result = unsafe {
            battbar_atk_decode(
                8,
                sample.as_ptr(),
                sample.len(),
                &mut reading,
                &mut device_status,
            )
        };
        assert_eq!(result, status::OK);
        assert_eq!(reading.battery, 100);
        assert_eq!(reading.charging, 1);

        let status_only = [0x04, 0x01, 0, 0, 0, 50, 0];
        // SAFETY: as above.
        let result = unsafe {
            battbar_atk_decode(
                8,
                status_only.as_ptr(),
                status_only.len(),
                &mut reading,
                &mut device_status,
            )
        };
        assert_eq!(result, status::ERROR_STATUS);
        assert_eq!(device_status, 1, "the device status byte is mirrored out");

        let foreign = [0x09, 0x04, 0, 0, 0, 50, 0];
        // SAFETY: as above.
        let result = unsafe {
            battbar_atk_decode(
                9,
                foreign.as_ptr(),
                foreign.len(),
                &mut reading,
                std::ptr::null_mut(),
            )
        };
        assert_eq!(result, status::NOT_FOR_US);
    }

    #[test]
    fn razer_round_trip() {
        let mut request = [0u8; 90];
        // SAFETY: the buffer matches the report length.
        let written = unsafe {
            battbar_razer_request(
                razer::COMMAND_CLASS,
                razer::BATTERY_COMMAND,
                request.as_mut_ptr(),
                request.len(),
            )
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
    fn exposes_the_retry_policy() {
        assert_eq!(
            battbar_retry_delay_ms(1, 0),
            battbar_core::retry::RETRY_DELAY_MS as i32
        );
        assert_eq!(battbar_retry_delay_ms(1, 1), -1);
        assert_eq!(battbar_retry_delay_ms(0, 0), -1);
    }

    #[test]
    fn merge_rejects_unknown_codes() {
        let ids = [CString::new("a").unwrap(), CString::new("b").unwrap()];
        let names = [CString::new("A").unwrap(), CString::new("B").unwrap()];
        let fresh = [
            BattbarDeviceSummary {
                id: ids[0].as_ptr(),
                name: names[0].as_ptr(),
                provider: 0,
                connection: 0,
            },
            // Unknown provider: the caller must be told, not silently reordered.
            BattbarDeviceSummary {
                id: ids[1].as_ptr(),
                name: names[1].as_ptr(),
                provider: 9,
                connection: 0,
            },
        ];
        let mut entries = [BattbarMergedDevice::default(); 2];
        let mut count = 0i32;
        let mut active = -1i32;
        // SAFETY: the arrays are valid for their advertised lengths.
        let result = unsafe {
            battbar_merge_scan(
                fresh.as_ptr(),
                fresh.len() as i32,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                entries.as_mut_ptr(),
                &mut count,
                &mut active,
            )
        };
        assert_eq!(result, status::ERROR_INVALID_ARGUMENT);
    }

    #[test]
    fn merge_maps_entries_back_to_the_inputs() {
        let ids = [
            CString::new("razer:1532:c1").unwrap(),
            CString::new("atk:373b:101a:x").unwrap(),
        ];
        let names = [CString::new("Razer").unwrap(), CString::new("ATK").unwrap()];
        // Deliberately out of order: the core sorts ATK before Razer.
        let fresh = [
            BattbarDeviceSummary {
                id: ids[0].as_ptr(),
                name: names[0].as_ptr(),
                provider: 1,
                connection: 0,
            },
            BattbarDeviceSummary {
                id: ids[1].as_ptr(),
                name: names[1].as_ptr(),
                provider: 0,
                connection: 0,
            },
        ];
        let mut entries = [BattbarMergedDevice::default(); 2];
        let mut count = 0i32;
        let mut active = -1i32;
        // SAFETY: the arrays are valid for their advertised lengths.
        let result = unsafe {
            battbar_merge_scan(
                fresh.as_ptr(),
                fresh.len() as i32,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                entries.as_mut_ptr(),
                &mut count,
                &mut active,
            )
        };
        assert_eq!(result, 0);
        assert_eq!(count, 2);
        assert_eq!((entries[0].from_previous, entries[0].index), (0, 1));
        assert_eq!((entries[1].from_previous, entries[1].index), (0, 0));
        assert_eq!(active, 0);
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
