//! Contract tests driven by `core/vectors/vectors.json`.
//!
//! The same file is replayed against the shipped Swift and JavaScript
//! implementations by `core/scripts/crosscheck-*`, which is what keeps the
//! three code paths honest. Anything asserted here is a promise to the
//! platform layers.

use std::collections::HashSet;
use std::path::PathBuf;

use battbar_core::alerts::{AlertDevice, AlertKind, AlertManager};
use battbar_core::{atk, battery, bluetooth, razer, Reading};
use serde_json::Value;

fn vectors() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vectors/vectors.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    serde_json::from_str(&raw).expect("vectors.json is valid JSON")
}

fn from_hex(hex: &str) -> Vec<u8> {
    let digits: Vec<u8> = hex
        .bytes()
        .filter(|byte| byte.is_ascii_hexdigit())
        .map(|byte| match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            _ => byte - b'A' + 10,
        })
        .collect();
    assert_eq!(digits.len() % 2, 0, "odd number of hex digits");
    digits
        .chunks_exact(2)
        .map(|pair| (pair[0] << 4) | pair[1])
        .collect()
}

fn string_array(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|item| item.as_str().unwrap_or_default().to_string())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn atk_request_matches_the_shared_vector() {
    let data = vectors();
    let expected = from_hex(data["atk"]["request_hex"].as_str().expect("request_hex"));
    assert_eq!(atk::battery_request().to_vec(), expected);
}

#[test]
fn atk_decode_cases() {
    let data = vectors();
    let cases = data["atk"]["decode"].as_array().expect("atk.decode");

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        let report_id = case["report_id"].as_u64().unwrap_or(0) as u8;
        let bytes = from_hex(case["hex"].as_str().expect("hex"));
        let expected = &case["expect"];

        match expected["kind"].as_str().expect("kind") {
            "reading" => {
                let expected_battery = expected["battery"].as_u64().expect("battery") as u8;
                let expected_charging = expected["charging"].as_bool().expect("charging");
                assert_eq!(
                    atk::decode(report_id, &bytes),
                    Some(Ok(Reading {
                        battery: expected_battery,
                        charging: expected_charging,
                    })),
                    "case: {name}"
                );
            }
            "status" => {
                let status = expected["status"].as_u64().expect("status") as u8;
                assert_eq!(
                    atk::decode(report_id, &bytes),
                    Some(Err(battbar_core::DecodeError::Status(status))),
                    "case: {name}"
                );
            }
            "not_for_us" => {
                assert_eq!(atk::decode(report_id, &bytes), None, "case: {name}");
            }
            other => panic!("unknown expectation kind {other} in case {name}"),
        }
    }
}

#[test]
fn razer_requests_match_the_shared_vectors() {
    let data = vectors();
    let cases = data["razer"]["requests"]
        .as_array()
        .expect("razer.requests");
    let report_length = data["razer"]["report_length"]
        .as_u64()
        .expect("report_length") as usize;

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        let command_id = case["command_id"].as_u64().unwrap_or(0) as u8;
        let request = razer::request(
            case["command_class"].as_u64().unwrap_or(0) as u8,
            command_id,
        );

        assert_eq!(request.len(), report_length, "case: {name}");
        assert_eq!(
            request[1],
            case["transaction_id"].as_u64().unwrap_or(0) as u8,
            "case: {name} transaction id"
        );
        assert_eq!(
            request[5],
            case["data_size"].as_u64().unwrap_or(0) as u8,
            "case: {name} data size"
        );
        assert_eq!(request[7], command_id, "case: {name} command id");
        assert_eq!(
            request[case["crc_index"].as_u64().unwrap_or(0) as usize],
            case["crc"].as_u64().unwrap_or(0) as u8,
            "case: {name} crc"
        );
    }
}

#[test]
fn razer_decode_cases() {
    let data = vectors();
    let cases = data["razer"]["decode"].as_array().expect("razer.decode");

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        let bytes = from_hex(case["hex"].as_str().expect("hex"));
        let expected = &case["expect"];

        match expected["kind"].as_str().expect("kind") {
            "battery" => {
                let expected_battery = expected["battery"].as_u64().expect("battery") as u8;
                assert_eq!(
                    razer::decode_battery(&bytes),
                    Ok(Reading {
                        battery: expected_battery,
                        charging: false,
                    }),
                    "case: {name}"
                );
                assert_eq!(
                    razer::battery(&bytes),
                    Some(expected_battery),
                    "case: {name}"
                );
            }
            "charging" => {
                let expected_charging = expected["charging"].as_bool().expect("charging");
                assert_eq!(
                    razer::charging(&bytes),
                    Some(expected_charging),
                    "case: {name}"
                );
                assert!(
                    razer::validate_response(&bytes, razer::COMMAND_CLASS, razer::CHARGING_COMMAND)
                        .is_ok(),
                    "case: {name}"
                );
            }
            "status" => {
                let status = expected["status"].as_u64().expect("status") as u8;
                assert_eq!(
                    razer::decode_battery(&bytes),
                    Err(battbar_core::DecodeError::Status(status)),
                    "case: {name}"
                );
            }
            "not_for_us" => {
                assert_eq!(
                    razer::decode_battery(&bytes),
                    Err(battbar_core::DecodeError::NotForUs),
                    "case: {name}"
                );
            }
            other => panic!("unknown expectation kind {other} in case {name}"),
        }
    }
}

#[test]
fn bluetooth_battery_attribute_cases() {
    let data = vectors();
    let cases = data["bluetooth"]["battery_attributes"]
        .as_array()
        .expect("bluetooth.battery_attributes");

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        let owned: Vec<(String, String)> = case["attributes"]
            .as_array()
            .expect("attributes")
            .iter()
            .map(|pair| {
                let pair = pair.as_array().expect("key/value pair");
                (
                    pair[0].as_str().unwrap_or_default().to_string(),
                    pair[1].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let attributes: Vec<(&str, &str)> = owned
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();

        let expected = match &case["expect"] {
            Value::Null => None,
            value => Some(value.as_u64().expect("battery") as u8),
        };
        assert_eq!(
            bluetooth::battery_from_attributes(&attributes),
            expected,
            "case: {name}"
        );
    }
}

#[test]
fn bluetooth_charging_attribute_cases() {
    let data = vectors();
    let cases = data["bluetooth"]["charging_attributes"]
        .as_array()
        .expect("bluetooth.charging_attributes");

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        let owned: Vec<(String, String)> = case["attributes"]
            .as_array()
            .expect("attributes")
            .iter()
            .map(|pair| {
                let pair = pair.as_array().expect("key/value pair");
                (
                    pair[0].as_str().unwrap_or_default().to_string(),
                    pair[1].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let attributes: Vec<(&str, &str)> = owned
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();

        let expected = case["expect"].as_bool();
        assert_eq!(
            bluetooth::charging_from_attributes(&attributes),
            expected,
            "case: {name}"
        );
    }
}

#[test]
fn bluetooth_mouse_name_cases() {
    let data = vectors();
    let cases = data["bluetooth"]["mouse_names"]
        .as_array()
        .expect("bluetooth.mouse_names");

    for case in cases {
        let name = case["name"].as_str().unwrap_or_default();
        let minor_type = case["minor_type"].as_str().unwrap_or_default();
        assert_eq!(
            bluetooth::is_likely_mouse(name, minor_type),
            case["expect"].as_bool().expect("expect"),
            "case: {name} / {minor_type}"
        );
    }
}

#[test]
fn alert_scenarios() {
    let data = vectors();
    let scenarios = data["alerts"]["scenarios"]
        .as_array()
        .expect("alerts.scenarios");

    for scenario in scenarios {
        let name = scenario["name"].as_str().unwrap_or("<unnamed>");
        let enabled = scenario["enabled"].as_bool().unwrap_or(true);
        let mut manager = AlertManager::new();

        for (index, step) in scenario["steps"]
            .as_array()
            .expect("steps")
            .iter()
            .enumerate()
        {
            let devices: Vec<AlertDevice<'_>> = step["devices"]
                .as_array()
                .expect("devices")
                .iter()
                .map(|device| {
                    let id = device["id"].as_str().unwrap_or_default();
                    let battery = device["battery"].as_u64().map(|value| value as u8);
                    AlertDevice {
                        id,
                        battery,
                        charging: device["charging"].as_bool(),
                        stale: device["stale"].as_bool().unwrap_or(false),
                    }
                })
                .collect();

            let expected = string_array(step, "expect");
            let actual: Vec<&'static str> = manager
                .evaluate(&devices, enabled)
                .into_iter()
                .map(|alert| alert.kind.key())
                .collect();

            // The scenario file lists alerts in the same order the manager
            // emits them (device order), so a plain comparison is enough.
            assert_eq!(actual, expected, "scenario {name}, step {index}");
        }
    }
}

#[test]
fn every_alert_kind_maps_to_a_unique_key() {
    let keys: HashSet<&str> = [AlertKind::Low, AlertKind::Critical]
        .iter()
        .map(AlertKind::key)
        .collect();
    assert_eq!(keys.len(), 2, "alert kinds must be distinguishable");
}

#[test]
fn percent_helper_covers_the_shared_scaling_rules() {
    assert_eq!(battery::scale_u8_percent(128), 50);
    assert_eq!(battery::scale_u8_percent(87), 34);
    assert_eq!(battery::scale_u8_percent(254), 100);
}

/// Raw IOKit enumerates one entry per device and only exposes the primary usage
/// page. This test pins that model down with a table captured from real
/// hardware, and checks it describes the same physical devices as the hidapi
/// table above.
#[test]
fn atk_candidate_filtering_on_a_real_iokit_table() {
    let data = vectors();
    let section = &data["atk"]["macos_devices"];
    let items = section["items"]
        .as_array()
        .expect("atk.macos_devices.items");

    let devices: Vec<battbar_core::HidDeviceInfo> = items
        .iter()
        .map(|item| battbar_core::HidDeviceInfo {
            path: item["path"].as_str().unwrap_or_default().to_string(),
            vendor_id: item["vendor_id"].as_u64().unwrap_or_default() as u16,
            product_id: item["product_id"].as_u64().unwrap_or_default() as u16,
            product: Some(item["product"].as_str().unwrap_or_default().to_string()),
            serial_number: None,
            interface: item["interface"].as_i64().map(|value| value as i32),
            usage_page: item["usage_page"].as_u64().map(|value| value as u16),
            usage: item["usage"].as_u64().map(|value| value as u16),
        })
        .collect();

    // The macOS rule selects the vendor-interface device.
    let candidates = atk::find_macos_candidates(&devices);
    let expected = section["expect_candidates"]
        .as_array()
        .expect("atk.macos_devices.expect_candidates");
    assert_eq!(candidates.len(), expected.len(), "macOS candidates");
    for (candidate, want) in candidates.iter().zip(expected.iter()) {
        assert_eq!(candidate.path, want["path"].as_str().unwrap_or_default());
        assert_eq!(
            candidate.usage_page,
            Some(want["usage_page"].as_u64().unwrap_or_default() as u16)
        );
    }

    // The 0xFF04/0x02 preference can never trigger on IOKit output, because
    // that collection is not separately enumerable. On this hardware the
    // interface-1 fallback happens to select the same physical interface, so
    // both rules agree — but only because the product string looks like an ATK
    // mouse. The core therefore exposes both rules instead of pretending one
    // fits every enumeration API.
    let windows_rule = atk::find_candidates(&devices);
    assert_eq!(
        windows_rule.len(),
        1,
        "the interface fallback should also select a vendor interface here"
    );
    assert_eq!(
        windows_rule[0].path, candidates[0].path,
        "both rules must point at the same physical interface"
    );
}

/// The two capture tables describe the same physical hardware through two
/// different APIs: grouping the per-collection list by `path` must reproduce
/// exactly the per-device list. This is what makes it safe to pick a rule based
/// on the enumeration API in use.
#[test]
fn the_two_atk_tables_describe_the_same_physical_devices() {
    let data = vectors();
    let collection_items = data["atk"]["devices"]["items"]
        .as_array()
        .expect("atk.devices.items");
    let device_items = data["atk"]["macos_devices"]["items"]
        .as_array()
        .expect("atk.macos_devices.items");

    let mut collection_paths: Vec<&str> = collection_items
        .iter()
        .map(|item| item["path"].as_str().unwrap_or_default())
        .collect();
    collection_paths.sort_unstable();
    collection_paths.dedup();

    let mut device_paths: Vec<&str> = device_items
        .iter()
        .map(|item| item["path"].as_str().unwrap_or_default())
        .collect();
    device_paths.sort_unstable();
    device_paths.dedup();

    assert_eq!(
        collection_paths, device_paths,
        "the per-collection table must group into the same physical paths"
    );
    assert_eq!(
        collection_paths.len(),
        3,
        "the real dongle exposes 3 physical devices"
    );
    assert_eq!(
        collection_items.len(),
        11,
        "hidapi expands those 3 devices into 11 collection entries"
    );
}

/// A per-collection (hidapi-shaped) table goes through the collection rule.
#[test]
fn atk_candidate_filtering_on_a_real_device_table() {
    let data = vectors();
    let section = &data["atk"]["devices"];
    let items = section["items"].as_array().expect("atk.devices.items");

    let devices: Vec<battbar_core::HidDeviceInfo> = items
        .iter()
        .map(|item| battbar_core::HidDeviceInfo {
            path: item["path"].as_str().unwrap_or_default().to_string(),
            vendor_id: item["vendor_id"].as_u64().unwrap_or_default() as u16,
            product_id: item["product_id"].as_u64().unwrap_or_default() as u16,
            product: Some(item["product"].as_str().unwrap_or_default().to_string()),
            serial_number: None,
            interface: item["interface"].as_i64().map(|value| value as i32),
            usage_page: item["usage_page"].as_u64().map(|value| value as u16),
            usage: item["usage"].as_u64().map(|value| value as u16),
        })
        .collect();

    let candidates = atk::find_candidates(&devices);
    let expected = section["expect_candidates"]
        .as_array()
        .expect("atk.devices.expect_candidates");

    assert_eq!(
        candidates.len(),
        expected.len(),
        "expected {} candidate(s) from the real table, got {}",
        expected.len(),
        candidates.len()
    );

    for (candidate, want) in candidates.iter().zip(expected.iter()) {
        assert_eq!(
            candidate.path,
            want["path"].as_str().unwrap_or_default(),
            "candidate path"
        );
        assert_eq!(
            candidate.usage_page,
            Some(want["usage_page"].as_u64().unwrap_or_default() as u16),
            "candidate usage page"
        );
        assert_eq!(
            candidate.usage,
            Some(want["usage"].as_u64().unwrap_or_default() as u16),
            "candidate usage"
        );
        assert_eq!(
            candidate.interface,
            want["interface"].as_i64().map(|value| value as i32),
            "candidate interface"
        );
    }

    // The exact vendor collection must win over the interface fallback.
    assert!(candidates
        .iter()
        .all(|candidate| candidate.usage_page == Some(atk::VENDOR_USAGE_PAGE)));
}
