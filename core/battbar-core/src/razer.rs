//! Razer Viper V3 Pro / HyperPolling 2.4G protocol.
//!
//! Razer devices speak a 90-byte HID feature report. The layout and transaction
//! ids follow OpenRazer's `razercommon` / `razermouse_driver`:
//!
//! ```text
//! 0     status          (0x02 ok, 0x01 busy-but-valid)
//! 1     transaction id   (0x1F for Viper V3 Pro / HyperPolling)
//! 2..3  remaining packets
//! 4     protocol type
//! 5     data size
//! 6     command class   (0x07)
//! 7     command id      (0x80 battery, 0x84 charging)
//! 8..87 arguments
//! 88    CRC             (XOR of bytes 2..87)
//! ```
//!
//! `battery = round(argument[1] * 100 / 255)` and `charging = argument[1] == 1`.
//!
//! ## Report-id prefix differences
//!
//! macOS IOKit returns the 90-byte struct as-is for feature reports whose
//! report id is 0, but some HID stacks prepend the id, giving 91 bytes with a
//! leading `0x00`. [`normalize_feature_report`] absorbs that so callers can
//! pass the buffer straight through.

use crate::battery::{normalized_percent, scale_u8_percent};
use crate::{DecodeError, HidDeviceInfo, Reading};

/// Length of a Razer feature report.
pub const REPORT_LENGTH: usize = 90;
/// Transaction id for the Viper V3 Pro / HyperPolling family.
pub const TRANSACTION_ID: u8 = 0x1f;
/// Command class used by the mouse commands we need.
pub const COMMAND_CLASS: u8 = 0x07;
/// "Read battery" command id.
pub const BATTERY_COMMAND: u8 = 0x80;
/// "Read charging state" command id.
pub const CHARGING_COMMAND: u8 = 0x84;
/// Data size field written into a request.
const DATA_SIZE: u8 = 0x02;
/// Index of the CRC byte.
const CRC_INDEX: usize = 88;
/// Index of the first argument byte in a response.
const ARGUMENT_INDEX: usize = 8;

/// Razer vendor id.
pub const VENDOR_ID: u16 = 0x1532;
/// Viper V3 Pro (`0x00C1`), HyperPolling receiver (`0x00B3`) and Viper V2 Pro
/// wired / wireless (`0x00A5` / `0x00A6`).
///
/// The V2 Pro pair was added after reading a real Viper V2 Pro on Windows
/// (2026-10-31); it speaks the same 90-byte report and transaction id.
pub const SUPPORTED_PIDS: [u16; 4] = [0x00c1, 0x00b3, 0x00a5, 0x00a6];
/// Generic Desktop / Mouse usage: the collection Razer mice answer on.
pub const MOUSE_USAGE_PAGE: u16 = 0x0001;
pub const MOUSE_USAGE: u16 = 0x0002;
/// Most collections to hand back to the platform layer.
pub const MAX_CANDIDATES: usize = 8;

/// Whether this HID node belongs to a supported Razer mouse.
pub fn is_candidate(device: &HidDeviceInfo) -> bool {
    device.vendor_id == VENDOR_ID && SUPPORTED_PIDS.contains(&device.product_id)
}

/// Rank a collection: interface 0 first, and the mouse collection inside it.
///
/// The Razer control interface is interface 0 (OpenRazer matches
/// `bInterfaceNumber == 0`), and on a Viper V2 Pro receiver its mouse
/// collection is the only one that accepts the 90-byte feature report. The
/// keyboard interfaces mirror a "mouse" collection too, so the usage pair alone
/// is not enough to pick the right node.
fn rank(device: &HidDeviceInfo) -> (u8, u8) {
    let interface = u8::from(device.interface != Some(0));
    let mouse =
        u8::from(device.usage_page != Some(MOUSE_USAGE_PAGE) || device.usage != Some(MOUSE_USAGE));
    (interface, mouse)
}

/// Select the collections worth probing, best first.
///
/// **Enumeration model: one entry per collection.** A Razer receiver exposes a
/// dozen collections (mouse, consumer control, keyboard, vendor-defined …) and
/// only one of them accepts the feature report: on a Viper V2 Pro receiver that
/// is the mouse collection of interface 0, while the others fail
/// `HidD_SetFeature` with `ERROR_INVALID_FUNCTION` (captured on Windows,
/// 2026-10-31). Ranking here means the platform layer only has to try the
/// candidates in order and keep the first one that answers.
///
/// Collections that share a device path and interface are the same endpoint, so
/// only the best-ranked one is kept.
pub fn find_candidates(devices: &[HidDeviceInfo]) -> Vec<&HidDeviceInfo> {
    let mut chosen: Vec<&HidDeviceInfo> = Vec::new();
    for device in devices.iter().filter(|device| is_candidate(device)) {
        match chosen
            .iter()
            .position(|other| other.path == device.path && other.interface == device.interface)
        {
            Some(slot) => {
                if rank(device) < rank(chosen[slot]) {
                    chosen[slot] = device;
                }
            }
            None => chosen.push(device),
        }
    }
    // `sort_by_key` is stable: equal ranks keep the enumeration order.
    chosen.sort_by_key(|device| rank(device));
    chosen.truncate(MAX_CANDIDATES);
    chosen
}

/// Build a 90-byte request for one command.
pub fn request(command_class: u8, command_id: u8) -> [u8; REPORT_LENGTH] {
    let mut report = [0u8; REPORT_LENGTH];
    report[1] = TRANSACTION_ID;
    report[5] = DATA_SIZE;
    report[6] = command_class;
    report[7] = command_id;
    let checksum = crc(&report);
    report[CRC_INDEX] = checksum;
    report
}

/// XOR of bytes `2..88`.
pub fn crc(report: &[u8]) -> u8 {
    if report.len() <= CRC_INDEX {
        return 0;
    }
    report[2..CRC_INDEX]
        .iter()
        .fold(0u8, |acc, byte| acc ^ byte)
}

/// Convenience wrapper for the battery command.
pub fn battery_request() -> [u8; REPORT_LENGTH] {
    request(COMMAND_CLASS, BATTERY_COMMAND)
}

/// Convenience wrapper for the charging command.
pub fn charging_request() -> [u8; REPORT_LENGTH] {
    request(COMMAND_CLASS, CHARGING_COMMAND)
}

/// Drop a leading report-id byte when the OS prepended one.
///
/// Returns the slice unchanged when it is a plain 90-byte report.
pub fn normalize_feature_report(bytes: &[u8]) -> &[u8] {
    if bytes.len() == REPORT_LENGTH + 1 && bytes[0] == 0x00 {
        &bytes[1..]
    } else {
        bytes
    }
}

/// Check that a response answers the command we sent.
pub fn validate_response(
    response: &[u8],
    command_class: u8,
    command_id: u8,
) -> Result<(), DecodeError> {
    let response = normalize_feature_report(response);
    if response.len() < 10 {
        return Err(DecodeError::TooShort);
    }
    // 0x02 = success, 0x01 = busy but the arguments are still valid.
    match response[0] {
        0x02 | 0x01 => {}
        status => return Err(DecodeError::Status(status)),
    }
    if response[6] != command_class || response[7] != command_id {
        return Err(DecodeError::NotForUs);
    }
    Ok(())
}

/// Decode the battery percentage from a battery-command response.
pub fn battery(response: &[u8]) -> Option<u8> {
    let response = normalize_feature_report(response);
    let raw = *response.get(ARGUMENT_INDEX + 1)?;
    Some(scale_u8_percent(raw))
}

/// Decode the charging flag from a charging-command response.
pub fn charging(response: &[u8]) -> Option<bool> {
    let response = normalize_feature_report(response);
    Some(*response.get(ARGUMENT_INDEX + 1)? == 1)
}

/// Decode a battery response into a [`Reading`], validating it first.
pub fn decode_battery(response: &[u8]) -> Result<Reading, DecodeError> {
    validate_response(response, COMMAND_CLASS, BATTERY_COMMAND)?;
    let response = normalize_feature_report(response);
    let battery = battery(response).ok_or(DecodeError::Malformed("missing battery argument"))?;
    Ok(Reading {
        battery,
        // The separate charging command fills this in; a battery response on
        // its own cannot tell us.
        charging: false,
    })
}

/// Human-facing naming for a Razer receiver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayName {
    pub name: String,
    pub subtitle: String,
}

/// Model names for the product ids we recognise, so a receiver that only
/// reports a dongle string still gets a useful title.
fn known_model_name(product_id: u16) -> Option<&'static str> {
    match product_id {
        0x00c1 => Some("Razer Viper V3 Pro"),
        0x00a5 | 0x00a6 => Some("Razer Viper V2 Pro"),
        _ => None,
    }
}

/// Build the panel/menu titles for a Razer product string.
pub fn make_display_name(product: &str, product_id: u16) -> DisplayName {
    let value = product.trim();
    let lower = value.to_ascii_lowercase();
    let is_dongle = lower.contains("dongle") || lower.contains("receiver");

    let name = if lower.contains("viper v3 pro") {
        "Razer Viper V3 Pro".to_string()
    } else if let Some(model) = known_model_name(product_id) {
        model.to_string()
    } else if !value.is_empty() && !is_dongle {
        value.to_string()
    } else {
        "Razer 无线鼠标".to_string()
    };

    DisplayName {
        name,
        subtitle: if value.is_empty() {
            "Razer HyperPolling".to_string()
        } else {
            value.to_string()
        },
    }
}

/// Stable identifier for the user's saved device selection.
pub fn stable_device_id(device: &HidDeviceInfo) -> String {
    format!("razer:{:x}:{:x}", device.vendor_id, device.product_id)
}

/// Non-ASCII friendly battery label, shared by UI layers.
pub fn battery_label(battery: Option<u8>) -> String {
    match battery {
        Some(battery) => format!("{}%", normalized_percent(i64::from(battery))),
        None => "--".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_request_matches_the_shared_vector() {
        let request = battery_request();
        assert_eq!(request.len(), REPORT_LENGTH);
        assert_eq!(request[1], TRANSACTION_ID);
        assert_eq!(request[5], DATA_SIZE);
        assert_eq!(request[6], COMMAND_CLASS);
        assert_eq!(request[7], BATTERY_COMMAND);
        // Captured from the shipped macOS implementation.
        assert_eq!(request[CRC_INDEX], 0x85);
    }

    #[test]
    fn charging_request_has_its_own_crc() {
        let request = charging_request();
        assert_eq!(request[7], CHARGING_COMMAND);
        assert_eq!(request[CRC_INDEX], 0x02 ^ 0x07 ^ 0x84);
        assert_eq!(request[CRC_INDEX], 0x81);
    }

    #[test]
    fn crc_is_the_xor_of_the_middle() {
        let request = battery_request();
        let mut expected = 0u8;
        for byte in &request[2..88] {
            expected ^= byte;
        }
        assert_eq!(request[CRC_INDEX], expected);
    }

    #[test]
    fn scales_the_reported_value() {
        let mut response = [0u8; REPORT_LENGTH];
        response[0] = 0x02;
        response[1] = TRANSACTION_ID;
        response[6] = COMMAND_CLASS;
        response[7] = BATTERY_COMMAND;
        response[9] = 128;
        assert_eq!(battery(&response), Some(50));

        response[9] = 255;
        assert_eq!(battery(&response), Some(100));

        response[9] = 0;
        assert_eq!(battery(&response), Some(0));
    }

    #[test]
    fn accepts_the_busy_status() {
        let mut response = [0u8; REPORT_LENGTH];
        response[0] = 0x01;
        response[6] = COMMAND_CLASS;
        response[7] = BATTERY_COMMAND;
        assert!(validate_response(&response, COMMAND_CLASS, BATTERY_COMMAND).is_ok());
    }

    #[test]
    fn rejects_a_failure_status() {
        let mut response = [0u8; REPORT_LENGTH];
        response[0] = 0x03;
        response[6] = COMMAND_CLASS;
        response[7] = BATTERY_COMMAND;
        assert_eq!(
            validate_response(&response, COMMAND_CLASS, BATTERY_COMMAND),
            Err(DecodeError::Status(0x03))
        );
    }

    #[test]
    fn rejects_a_mismatched_command() {
        let mut response = [0u8; REPORT_LENGTH];
        response[0] = 0x02;
        response[6] = COMMAND_CLASS;
        response[7] = CHARGING_COMMAND;
        assert_eq!(
            validate_response(&response, COMMAND_CLASS, BATTERY_COMMAND),
            Err(DecodeError::NotForUs)
        );
    }

    #[test]
    fn absorbs_a_prepended_report_id() {
        let mut prefixed = vec![0x00u8];
        prefixed.extend_from_slice(&[0u8; REPORT_LENGTH]);
        prefixed[1] = 0x02;
        prefixed[7] = COMMAND_CLASS;
        prefixed[8] = BATTERY_COMMAND;
        prefixed[10] = 128;

        assert_eq!(normalize_feature_report(&prefixed).len(), REPORT_LENGTH);
        assert!(validate_response(&prefixed, COMMAND_CLASS, BATTERY_COMMAND).is_ok());
        assert_eq!(battery(&prefixed), Some(50));
    }

    #[test]
    fn decodes_charging() {
        let mut response = [0u8; REPORT_LENGTH];
        response[0] = 0x02;
        response[6] = COMMAND_CLASS;
        response[7] = CHARGING_COMMAND;
        response[9] = 1;
        assert_eq!(charging(&response), Some(true));
        response[9] = 0;
        assert_eq!(charging(&response), Some(false));
    }

    #[test]
    fn names_the_supported_devices() {
        let viper = make_display_name("Razer Viper V3 Pro", 0x00c1);
        assert_eq!(viper.name, "Razer Viper V3 Pro");

        let dongle = make_display_name("Razer HyperPolling Wireless Dongle", 0x00b3);
        // The 0x00B3 receiver can host any Viper, so it keeps the generic name —
        // this matches the shipped macOS behaviour.
        assert_eq!(dongle.name, "Razer 无线鼠标");
        assert_eq!(dongle.subtitle, "Razer HyperPolling Wireless Dongle");

        let unknown = make_display_name("", 0x00b3);
        assert_eq!(unknown.name, "Razer 无线鼠标");
    }

    #[test]
    fn filters_candidates_by_vendor_and_pid() {
        let supported = HidDeviceInfo {
            vendor_id: VENDOR_ID,
            product_id: 0x00c1,
            ..Default::default()
        };
        assert!(is_candidate(&supported));

        let v2_pro = HidDeviceInfo {
            vendor_id: VENDOR_ID,
            product_id: 0x00a6,
            ..Default::default()
        };
        assert!(is_candidate(&v2_pro), "Viper V2 Pro wireless");

        let other_pid = HidDeviceInfo {
            vendor_id: VENDOR_ID,
            product_id: 0x0c05,
            ..Default::default()
        };
        assert!(!is_candidate(&other_pid));
    }

    /// The collection list a Viper V2 Pro receiver exposes on Windows
    /// (SetupAPI, 2026-10-31). Only interface 0's mouse collection answers the
    /// feature report; the others fail with `ERROR_INVALID_FUNCTION`.
    fn viper_v2_pro_collections() -> Vec<HidDeviceInfo> {
        let node = |path: &str, interface: i32, page: u16, usage: u16| HidDeviceInfo {
            path: path.to_string(),
            vendor_id: VENDOR_ID,
            product_id: 0x00a6,
            product: Some("Razer Viper V2 Pro".into()),
            serial_number: Some("000000000000".into()),
            interface: Some(interface),
            usage_page: Some(page),
            usage: Some(usage),
        };
        vec![
            node(r"\\?\hid#vid_1532&pid_00a6&mi_01&col01", 1, 0x0001, 0x0002),
            node(r"\\?\hid#vid_1532&pid_00a6&mi_01&col02", 1, 0x000c, 0x0001),
            node(r"\\?\hid#vid_1532&pid_00a6&mi_01&col03", 1, 0x0001, 0x0006),
            node(r"\\?\hid#vid_1532&pid_00a6&mi_02&col01", 2, 0x0001, 0x0006),
            node(r"\\?\hid#vid_1532&pid_00a6&mi_01&col05", 1, 0x0001, 0x0080),
            node(r"\\?\hid#vid_1532&pid_00a6&mi_00&col01", 0, 0x0001, 0x0002),
        ]
    }

    #[test]
    fn tries_the_mouse_collection_first() {
        let devices = viper_v2_pro_collections();
        let candidates = find_candidates(&devices);
        assert_eq!(candidates[0].interface, Some(0));
        assert_eq!(candidates[0].usage, Some(MOUSE_USAGE));
        assert_eq!(
            candidates.len(),
            6,
            "every distinct collection is a candidate"
        );
        // Behind it: the mouse collection of the keyboard interface, then the
        // remaining collections in enumeration order.
        assert_eq!(candidates[1].interface, Some(1));
        assert_eq!(candidates[1].usage, Some(MOUSE_USAGE));
    }

    #[test]
    fn dedupes_collections_on_the_same_endpoint() {
        let devices = viper_v2_pro_collections();
        let mut duplicated = devices.clone();
        // A second collection on the same path+interface is the same endpoint.
        duplicated.push(HidDeviceInfo {
            path: devices[0].path.clone(),
            interface: devices[0].interface,
            vendor_id: VENDOR_ID,
            product_id: 0x00a6,
            usage_page: Some(0x0001),
            usage: Some(0x0001),
            product: Some("Razer Viper V2 Pro".into()),
            ..Default::default()
        });
        let candidates = find_candidates(&duplicated);
        assert_eq!(candidates.len(), devices.len());
        assert_eq!(candidates[0].usage, Some(MOUSE_USAGE));
    }

    #[test]
    fn decodes_a_captured_viper_v2_pro_response() {
        // Captured on Windows 2026-10-31: 91 bytes, leading report id, then the
        // 90-byte struct. arguments[1] = 0xFF → 100%.
        let mut response = vec![0u8; REPORT_LENGTH + 1];
        response[1] = 0x02; // status
        response[2] = TRANSACTION_ID;
        response[6] = DATA_SIZE;
        response[7] = COMMAND_CLASS;
        response[8] = BATTERY_COMMAND;
        response[10] = 0xff;

        assert_eq!(battery(&response), Some(100));
        assert!(validate_response(&response, COMMAND_CLASS, BATTERY_COMMAND).is_ok());
        assert_eq!(
            decode_battery(&response).map(|reading| reading.battery),
            Ok(100)
        );

        // The charging response from the same device: arguments[1] = 0.
        let mut charging_response = response.clone();
        charging_response[8] = CHARGING_COMMAND;
        charging_response[10] = 0x00;
        assert!(validate_response(&charging_response, COMMAND_CLASS, CHARGING_COMMAND).is_ok());
        assert_eq!(charging(&charging_response), Some(false));
    }

    #[test]
    fn names_the_viper_v2_pro() {
        let named = make_display_name("Razer Viper V2 Pro", 0x00a6);
        assert_eq!(named.name, "Razer Viper V2 Pro");
        // Even when the receiver only reports a dongle string.
        let bare = make_display_name("Razer Wireless Dongle", 0x00a6);
        assert_eq!(bare.name, "Razer Viper V2 Pro");
    }
}
