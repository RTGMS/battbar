//! ATK / VXE / MAD 2.4G receiver protocol (Compx).
//!
//! The receiver exposes a 16-byte vendor report through HID report id `0x08`.
//! Byte 0 is the command (`0x04` = read battery), byte 15 is a checksum seeded
//! with the report id:
//!
//! ```text
//! checksum = (0x55 - ((0x08 + sum(payload[0..14])) & 0xFF)) & 0xFF
//! ```
//!
//! macOS expects the report id as the first byte of the buffer handed to
//! `IOHIDDeviceSetReport`, so [`battery_request`] returns 17 bytes: the report
//! id followed by the 16-byte packet. Windows HIDAPI wants the same shape. The
//! only difference between platforms is how the buffer is passed down, which
//! is the platform layer's problem, not ours.

use crate::battery::normalized_percent;
use crate::{DecodeError, HidDeviceInfo, Reading};

/// HID report id used for the battery command.
pub const REPORT_ID: u8 = 0x08;
/// Command byte for "read battery".
pub const COMMAND_BATTERY: u8 = 0x04;
/// Length of the report payload, excluding the report id.
pub const PACKET_LENGTH: usize = 16;
/// Length of the buffer handed to the OS, including the report id.
pub const REQUEST_LENGTH: usize = PACKET_LENGTH + 1;

/// Known Compx/ATK vendor ids.
pub const VENDOR_IDS: [u16; 2] = [0x373b, 0x3554];
/// Vendor-defined usage page that marks the control collection.
pub const VENDOR_USAGE_PAGE: u16 = 0xff04;
/// Vendor-defined usage that marks the control collection.
pub const VENDOR_USAGE: u16 = 0x02;

/// Maximum number of receivers we are willing to probe in one scan.
pub const MAX_CANDIDATES: usize = 4;

/// Build the 17-byte buffer for a battery request (report id included).
pub fn battery_request() -> [u8; REQUEST_LENGTH] {
    let mut packet = [0u8; REQUEST_LENGTH];
    packet[0] = REPORT_ID;
    packet[1] = COMMAND_BATTERY;

    let mut sum = 0u32;
    for byte in &packet[..REQUEST_LENGTH - 1] {
        sum += u32::from(*byte);
    }
    packet[REQUEST_LENGTH - 1] = ((0x55 - (sum & 0xff)) & 0xff) as u8;
    packet
}

/// Decode a report read from the device.
///
/// Returns `None` when the buffer is not an ATK battery report at all (the
/// caller should keep reading), and `Some(Err(..))` when it is an ATK report
/// that reports a failure.
///
/// `report_id` is the id the OS reported for this read. Some HID stacks already
/// prepend it to `bytes`; both shapes are accepted, matching the shipped macOS
/// behaviour.
pub fn decode(report_id: u8, bytes: &[u8]) -> Option<Result<Reading, DecodeError>> {
    let payload = match bytes.first() {
        Some(&REPORT_ID) => &bytes[1..],
        _ if report_id != REPORT_ID => return None,
        _ => bytes,
    };

    if payload.len() < 7 || payload[0] != COMMAND_BATTERY {
        return None;
    }
    if payload[1] != 0 {
        return Some(Err(DecodeError::Status(payload[1])));
    }

    Some(Ok(Reading {
        battery: normalized_percent(i64::from(payload[5])),
        charging: payload[6] == 1,
    }))
}

/// Whether this HID node is worth opening for a battery query.
///
/// **Enumeration model: one entry per collection.**
///
/// This is the shape produced by hidapi — and therefore by `node-hid` on every
/// platform, and by the Rust `hidapi` crate on Windows. On macOS, hidapi takes
/// the three IOKit devices and expands each one into one entry per usage pair
/// (see `hidapi/mac/hid.c`, `create_device_info`), so the vendor collection
/// (`usage_page 0xFF04` / `usage 0x02`) becomes separately visible and can be
/// preferred.
///
/// Some HID stacks only expose the first top-level collection, so interface 1
/// of a plausible product is accepted as a fallback.
///
/// The Swift app does **not** see this shape: it talks to IOKit directly, which
/// reports one entry per device and only the primary usage page. Use
/// [`is_macos_candidate`] for that model.
pub fn is_candidate(device: &HidDeviceInfo) -> bool {
    if !VENDOR_IDS.contains(&device.vendor_id) {
        return false;
    }
    if device.usage_page == Some(VENDOR_USAGE_PAGE) && device.usage == Some(VENDOR_USAGE) {
        return true;
    }
    device.interface == Some(1) && looks_like_atk_product(device.product_str())
}

/// Lowest usage page that marks an ATK vendor interface.
pub const VENDOR_USAGE_PAGE_FLOOR: u16 = 0xff00;

/// Whether an IOKit-enumerated device is worth opening.
///
/// **Enumeration model: one entry per device.**
///
/// Raw IOKit (`IOHIDManagerCopyDevices`) returns one entry per device and only
/// the primary usage page: a real ATK 1K receiver reports `0xFF05` there, and
/// the `0xFF04/0x02` collection it also contains is not separately enumerable.
/// The shipped Swift provider therefore accepts any vendor usage page in the
/// `0xFF00..=0xFFFF` range; this keeps that behaviour and adds the vendor id
/// check the Swift version got from its IOHIDManager matching dictionary.
///
/// This is about the *API*, not the operating system: hidapi on macOS returns
/// the per-collection shape and must use [`is_candidate`] instead.
pub fn is_macos_candidate(device: &HidDeviceInfo) -> bool {
    VENDOR_IDS.contains(&device.vendor_id)
        && device
            .usage_page
            .is_some_and(|page| page >= VENDOR_USAGE_PAGE_FLOOR)
}

/// Filter a per-device (IOKit) enumeration list, mirroring the shipped Swift
/// rule. See [`is_macos_candidate`].
pub fn find_macos_candidates(devices: &[HidDeviceInfo]) -> Vec<&HidDeviceInfo> {
    devices
        .iter()
        .filter(|device| is_macos_candidate(device))
        .collect()
}

/// Loose product-name check used only for the interface fallback.
pub fn looks_like_atk_product(product: &str) -> bool {
    const NEEDLES: [&str; 8] = [
        "vxe",
        "mad",
        "compx",
        "mouse",
        "mice",
        "dongle",
        "receiver",
        "接收器",
    ];
    let haystack = product.to_ascii_lowercase();
    NEEDLES.iter().any(|needle| haystack.contains(needle)) || product.contains("鼠标")
}

/// Deduplicate per-collection enumeration output into at most
/// [`MAX_CANDIDATES`] receivers.
///
/// Devices are grouped by `(path, interface)`; an exact vendor collection wins
/// over the interface fallback for the same group. Expects the hidapi shape
/// (see [`is_candidate`]).
pub fn find_candidates(devices: &[HidDeviceInfo]) -> Vec<&HidDeviceInfo> {
    /// `(group key, chosen device, chosen device is the exact collection)`
    type Group<'a> = ((&'a str, Option<i32>), &'a HidDeviceInfo, bool);

    let mut grouped: Vec<Group<'_>> = Vec::new();

    for device in devices {
        if !is_candidate(device) {
            continue;
        }
        let key = (device.path.as_str(), device.interface);
        let exact =
            device.usage_page == Some(VENDOR_USAGE_PAGE) && device.usage == Some(VENDOR_USAGE);
        match grouped.iter_mut().find(|(existing, _, _)| *existing == key) {
            Some(slot) => {
                if exact && !slot.2 {
                    slot.1 = device;
                    slot.2 = true;
                }
            }
            None => grouped.push((key, device, exact)),
        }
    }

    grouped
        .into_iter()
        .map(|(_, device, _)| device)
        .take(MAX_CANDIDATES)
        .collect()
}

/// Human-facing naming derived from the receiver product string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayName {
    pub name: String,
    pub subtitle: String,
    pub connection_label: &'static str,
}

/// Build the panel/menu titles for a receiver product string.
pub fn make_display_name(product: &str) -> DisplayName {
    let value = product.trim();
    let brand = brand_from_product(value);
    let lower = value.to_ascii_lowercase();
    let is_dongle =
        lower.contains("dongle") || lower.contains("receiver") || value.contains("接收器");

    if is_dongle {
        return DisplayName {
            name: format!("{brand} 无线鼠标"),
            subtitle: if value.is_empty() {
                format!("{brand} 接收器")
            } else {
                value.to_string()
            },
            connection_label: "2.4 GHz",
        };
    }

    // Not a receiver, so the product string is the mouse itself.
    DisplayName {
        name: if value.is_empty() {
            format!("{brand} 无线鼠标")
        } else {
            value.to_string()
        },
        subtitle: if value.is_empty() {
            format!("{brand} HID")
        } else {
            value.to_string()
        },
        connection_label: "2.4 GHz",
    }
}

fn brand_from_product(product: &str) -> &'static str {
    let lower = product.to_ascii_lowercase();
    if lower.contains("vxe") {
        "VXE"
    } else if lower.contains("mad") {
        "MAD"
    } else {
        "ATK"
    }
}

/// Stable identifier for the user's saved device selection.
///
/// The serial number is authoritative. When the receiver has none (the common
/// case), a short SHA-1 fingerprint of `vendor:product:name` is used instead —
/// the raw HID path changes on reconnect and would lose the selection.
///
/// The fingerprint format matches the Electron implementation so that a
/// Windows user upgrading from the legacy app keeps their selection.
pub fn stable_device_id(device: &HidDeviceInfo) -> String {
    let serial = device.serial_str();
    let suffix = if serial.is_empty() {
        let fingerprint = sha1_hex(
            format!(
                "{}:{}:{}",
                device.vendor_id,
                device.product_id,
                device.product_str()
            )
            .as_bytes(),
        );
        fingerprint[..8].to_string()
    } else {
        serial.to_string()
    };
    format!(
        "atk:{:x}:{:x}:{}",
        device.vendor_id, device.product_id, suffix
    )
}

/// Minimal SHA-1, used only for the stable-id fingerprint.
fn sha1_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in message.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (index, word) in chunk.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..80 {
            w[index] = (w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]).rotate_left(1);
        }

        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (index, word) in w.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }

    h.iter().map(|word| format!("{word:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dongle() -> HidDeviceInfo {
        HidDeviceInfo {
            path: "DevSrvsID:4295619567".into(),
            vendor_id: 0x373b,
            product_id: 0x101a,
            product: Some("ATK Mouse 1K Dongle".into()),
            interface: Some(1),
            usage_page: Some(0x01),
            usage: Some(0x06),
            ..Default::default()
        }
    }

    #[test]
    fn request_matches_the_shipped_vector() {
        let request = battery_request();
        assert_eq!(request.len(), REQUEST_LENGTH);
        assert_eq!(&request[..2], &[0x08, 0x04]);
        assert_eq!(request[REQUEST_LENGTH - 1], 0x49);
        assert_eq!(
            request,
            [0x08, 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x49]
        );
    }

    #[test]
    fn checksum_formula_is_reproducible() {
        let request = battery_request();
        let sum: u32 = request[..REQUEST_LENGTH - 1]
            .iter()
            .map(|byte| u32::from(*byte))
            .sum();
        assert_eq!(
            request[REQUEST_LENGTH - 1],
            ((0x55 - (sum & 0xff)) & 0xff) as u8
        );
    }

    #[test]
    fn decodes_a_full_report() {
        let sample = [
            0x08, 0x04, 0, 0, 0, 0x02, 0x64, 0x01, 0x10, 0x72, 0, 0, 0, 0, 0, 0, 0x60,
        ];
        assert_eq!(
            decode(REPORT_ID, &sample),
            Some(Ok(Reading {
                battery: 100,
                charging: true
            }))
        );
    }

    #[test]
    fn decodes_without_the_report_id_prefix() {
        let payload = [0x04, 0, 0, 0, 0x02, 0x64, 0x01];
        assert_eq!(
            decode(REPORT_ID, &payload),
            Some(Ok(Reading {
                battery: 100,
                charging: true
            }))
        );
    }

    #[test]
    fn reports_non_zero_status() {
        let payload = [0x04, 0x01, 0, 0, 0, 50, 0];
        assert_eq!(
            decode(REPORT_ID, &payload),
            Some(Err(DecodeError::Status(1)))
        );
    }

    #[test]
    fn ignores_other_report_ids() {
        assert_eq!(decode(9, &[0x09, 0x04, 0, 0, 0, 50, 0]), None);
    }

    #[test]
    fn rejects_short_reports() {
        // Fewer than 7 payload bytes: not decodable, keep reading.
        assert_eq!(decode(REPORT_ID, &[0x08, 0x04, 0, 0, 0, 50]), None);
    }

    #[test]
    fn filters_keyboards_on_the_interface_fallback() {
        let mut keyboard = dongle();
        keyboard.product = Some("ATK Keyboard 68".into());
        assert!(!is_candidate(&keyboard));

        let mouse = dongle();
        assert!(is_candidate(&mouse));
    }

    #[test]
    fn prefers_the_vendor_collection_and_dedupes() {
        let mut fallback = dongle();
        fallback.usage_page = Some(0x01);
        fallback.usage = Some(0x06);

        let mut exact = dongle();
        exact.usage_page = Some(VENDOR_USAGE_PAGE);
        exact.usage = Some(VENDOR_USAGE);

        let devices = [fallback.clone(), exact.clone()];
        let candidates = find_candidates(&devices);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].usage_page, Some(VENDOR_USAGE_PAGE));

        // Order should not matter.
        let reversed_devices = [exact, fallback];
        let reversed = find_candidates(&reversed_devices);
        assert_eq!(reversed.len(), 1);
        assert_eq!(reversed[0].usage_page, Some(VENDOR_USAGE_PAGE));
    }

    #[test]
    fn caps_the_candidate_list() {
        let devices: Vec<HidDeviceInfo> = (0..10)
            .map(|index| HidDeviceInfo {
                path: format!("path-{index}"),
                ..dongle()
            })
            .collect();
        assert_eq!(find_candidates(&devices).len(), MAX_CANDIDATES);
    }

    #[test]
    fn names_dongles_and_products() {
        let name = make_display_name("ATK Mouse 1K Dongle");
        assert_eq!(name.name, "ATK 无线鼠标");
        assert_eq!(name.subtitle, "ATK Mouse 1K Dongle");

        let vxe = make_display_name("VXE R1 Pro Dongle");
        assert_eq!(vxe.name, "VXE 无线鼠标");

        // A string that mentions a receiver is treated as one, whatever else it
        // says: the mouse model is not in it.
        let suffix = make_display_name("ATK Mouse 4K Wireless Dongle");
        assert_eq!(suffix.name, "ATK 无线鼠标");

        // Without a receiver word the string is the mouse itself.
        let plain = make_display_name("MAD R 8K");
        assert_eq!(plain.name, "MAD R 8K");
    }

    #[test]
    fn stable_id_matches_the_legacy_electron_format() {
        // Captured from the shipped Electron implementation:
        // sha1("15163:4122:ATK Mouse 1K Dongle")[..8] == "536b2ba7"
        assert_eq!(stable_device_id(&dongle()), "atk:373b:101a:536b2ba7");
    }

    #[test]
    fn stable_id_prefers_the_serial_number() {
        let mut device = dongle();
        device.serial_number = Some("ABC123".into());
        assert_eq!(stable_device_id(&device), "atk:373b:101a:ABC123");
    }

    #[test]
    fn sha1_matches_known_digests() {
        assert_eq!(sha1_hex(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            sha1_hex(b"The quick brown fox jumps over the lazy dog"),
            "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"
        );
    }
}
