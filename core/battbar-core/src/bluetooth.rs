//! Battery records scraped from the operating system.
//!
//! Two very different payloads end up here:
//!
//! * **macOS** – `system_profiler SPBluetoothDataType -json` returns a nested
//!   dictionary of attributes per device (`device_batteryLevelMain`,
//!   `device_charging`, ...). The platform layer flattens one device into
//!   key/value pairs and calls [`battery_from_attributes`] /
//!   [`charging_from_attributes`].
//! * **Windows** – the tray app walks the PnP registry for the battery
//!   property; it keeps a node only when [`is_likely_mouse`] matches, the
//!   value survives [`battery_from_attributes`], and the PnP tree does not
//!   report the node as absent.
//!
//! Keeping the *selection rules* here is the whole point: the heuristics had
//! drifted between the Swift and JavaScript implementations, and now there is
//! one place to fix them.

use crate::battery::parse_percent_text;

/// Attribute keys checked in order on macOS.
pub const PREFERRED_BATTERY_KEYS: [&str; 4] = [
    "device_batteryLevelMain",
    "device_batteryLevel",
    "device_batteryPercent",
    "device_batteryLevelCombined",
];

/// Charging attribute keys checked in order on macOS.
pub const CHARGING_KEYS: [&str; 4] = [
    "device_charging",
    "device_batteryCharging",
    "device_batteryIsCharging",
    "charging",
];

/// Keys that describe a case/bud/secondary battery and must not win.
const EXCLUDED_BATTERY_FRAGMENTS: [&str; 4] = ["case", "left", "right", "secondary"];

/// Brand/model keywords used to recognise a mouse by name.
///
/// The list is matched case-insensitively and ignores whitespace, so
/// `MX Master` also matches `mxmaster`. It is intentionally loose: a false
/// positive only adds a row to the panel, while a false negative hides a
/// device the user cares about.
pub const MOUSE_KEYWORDS: [&str; 44] = [
    "mouse",
    "mice",
    "鼠标",
    "atk",
    "vxe",
    "madr",
    "logitech",
    "罗技",
    "razer",
    "雷蛇",
    "pulsar",
    "lamzu",
    "ninja",
    "glorious",
    "zowie",
    "benq",
    "steelseries",
    "赛睿",
    "roccat",
    "corsair",
    "海盗船",
    "hyperx",
    "pwnage",
    "finalmouse",
    "endgame",
    "wlmouse",
    "hitscan",
    "arbiter",
    "scyrox",
    "incott",
    "waizowl",
    "darmoshark",
    "ajazz",
    "mchose",
    "attackshark",
    "gpro",
    "mxmaster",
    "mxanywhere",
    "deathadder",
    "viper",
    "basilisk",
    "aerox",
    "rival",
    "wirelessmouse",
];

/// Whether a device name / minor type combination looks like a mouse.
///
/// `minor_type` is the macOS `device_minorType` value (or the Windows device
/// class). An explicit `mouse` / `pointing` minor type always wins.
pub fn is_likely_mouse(name: &str, minor_type: &str) -> bool {
    let minor_lower = minor_type.to_ascii_lowercase();
    if minor_lower.contains("mouse") || minor_lower.contains("pointing") {
        return true;
    }
    let haystack = squash(&format!("{name} {minor_type}"));
    MOUSE_KEYWORDS
        .iter()
        .any(|keyword| haystack.contains(&squash(keyword)))
}

/// Lowercase and remove whitespace so `mad r` matches `madr`.
fn squash(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Pick the battery percentage out of a flattened attribute list.
///
/// Preferred keys are checked first; afterwards any `device_battery*` key is
/// accepted as long as it does not describe a secondary cell.
pub fn battery_from_attributes(attributes: &[(&str, &str)]) -> Option<u8> {
    for key in PREFERRED_BATTERY_KEYS {
        if let Some((_, value)) = attributes.iter().find(|(candidate, _)| *candidate == key) {
            if let Some(parsed) = parse_percent_text(value) {
                return Some(parsed);
            }
        }
    }

    for (key, value) in attributes {
        let lower = key.to_ascii_lowercase();
        if !lower.starts_with("device_battery") {
            continue;
        }
        if EXCLUDED_BATTERY_FRAGMENTS
            .iter()
            .any(|fragment| lower.contains(fragment))
        {
            continue;
        }
        if let Some(parsed) = parse_percent_text(value) {
            return Some(parsed);
        }
    }

    None
}

/// Pick the charging flag out of a flattened attribute list.
pub fn charging_from_attributes(attributes: &[(&str, &str)]) -> Option<bool> {
    for key in CHARGING_KEYS {
        if let Some((_, value)) = attributes.iter().find(|(candidate, _)| *candidate == key) {
            if let Some(parsed) = parse_bool(value) {
                return Some(parsed);
            }
        }
    }
    None
}

/// Parse the many spellings of a boolean that the OSes produce.
pub fn parse_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "yes" | "true" | "1" | "charging" | "on" => Some(true),
        "no" | "false" | "0" | "discharging" | "off" => Some(false),
        _ => None,
    }
}

/// macOS device id, derived from the Bluetooth address when available.
pub fn macos_device_id(address: &str, name: &str) -> String {
    let address = address.trim().to_ascii_lowercase();
    if address.is_empty() {
        format!("bt-macos:{}", name.trim().to_ascii_lowercase())
    } else {
        format!("bt-macos:{address}")
    }
}

/// Windows device id, derived from the PnP instance id.
pub fn windows_device_id(instance_id: &str) -> String {
    format!("bt-win:{instance_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_the_main_battery_key() {
        let attributes = [
            ("device_batteryLevelCase", "90%"),
            ("device_batteryLevelMain", "75%"),
        ];
        assert_eq!(battery_from_attributes(&attributes), Some(75));
    }

    #[test]
    fn falls_back_to_any_device_battery_key() {
        let attributes = [("device_batteryPercentCombined", "42")];
        assert_eq!(battery_from_attributes(&attributes), Some(42));
    }

    #[test]
    fn ignores_secondary_cells() {
        let attributes = [
            ("device_batteryLevelLeft", "80%"),
            ("device_batteryLevelRight", "70%"),
            ("device_batteryLevelCase", "60%"),
        ];
        assert_eq!(battery_from_attributes(&attributes), None);
    }

    #[test]
    fn rejects_out_of_range_values() {
        assert_eq!(
            battery_from_attributes(&[("device_batteryLevelMain", "101%")]),
            None
        );
        assert_eq!(
            battery_from_attributes(&[("device_batteryLevelMain", "-5%")]),
            None
        );
    }

    #[test]
    fn parses_charging_spellings() {
        for value in ["Yes", "true", "1", "charging", "on"] {
            assert_eq!(
                charging_from_attributes(&[("device_charging", value)]),
                Some(true)
            );
        }
        for value in ["No", "false", "0", "discharging", "off"] {
            assert_eq!(
                charging_from_attributes(&[("device_charging", value)]),
                Some(false)
            );
        }
        assert_eq!(
            charging_from_attributes(&[("device_charging", "maybe")]),
            None
        );
    }

    #[test]
    fn recognises_mice_by_name_and_type() {
        assert!(is_likely_mouse("MX Master 3S", "Mouse"));
        assert!(is_likely_mouse("Some Device", "Pointing"));
        assert!(is_likely_mouse("MX Master 3S", ""));
        assert!(is_likely_mouse("Mad R 8K", ""));
        assert!(is_likely_mouse("ATK 无线鼠标", ""));

        // Keyword lists that only exist in one of the old implementations.
        assert!(is_likely_mouse("Attack Shark X3", ""));
        assert!(is_likely_mouse("Logitech G PRO X Superlight", ""));
        assert!(is_likely_mouse("Pulsar X2V2", ""));

        // Must not match a keyboard or headphones.
        assert!(!is_likely_mouse("Magic Keyboard", "Keyboard"));
        assert!(!is_likely_mouse("AirPods Pro", "Headphones"));
    }

    #[test]
    fn whitespace_insensitive_keyword_matching() {
        assert!(is_likely_mouse("mx master 3", ""));
        assert!(is_likely_mouse("WL Mouse Beast X", ""));
        assert!(is_likely_mouse("G PRO Wireless", ""));
    }

    #[test]
    fn builds_stable_macos_ids() {
        assert_eq!(
            macos_device_id("AA-BB-CC-DD-EE-FF", "MX Master 3S"),
            "bt-macos:aa-bb-cc-dd-ee-ff"
        );
        assert_eq!(macos_device_id("", "MX Master 3S"), "bt-macos:mx master 3s");
    }

    #[test]
    fn builds_windows_ids() {
        assert_eq!(windows_device_id("BTHLE\\DEV_ABC"), "bt-win:BTHLE\\DEV_ABC");
    }
}
