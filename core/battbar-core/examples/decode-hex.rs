//! Decode a raw HID report captured from a device.
//!
//! Useful during hardware validation: paste the hex you recorded with
//! `node tools/hid-probe.js atk` (or the probes in `TODO.md`) and see exactly
//! what the core makes of it.
//!
//! ```text
//! cargo run --example decode-hex -- atk   0804000000025f00100d000000000000cb
//! cargo run --example decode-hex -- razer 02001f000002078000ff000000000000...
//! ```
//!
//! Exit codes: 0 decoded, 1 the report is not ours, 2 a protocol error,
//! 64 usage error.

use std::process::ExitCode;

use battbar_core::{atk, razer, DecodeError};

fn parse_hex(input: &str) -> Result<Vec<u8>, String> {
    let digits: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    if digits.len() % 2 != 0 {
        return Err("hex string has an odd number of digits".to_string());
    }
    let mut bytes = Vec::with_capacity(digits.len() / 2);
    for pair in digits.chunks_exact(2) {
        let high = (pair[0] as char)
            .to_digit(16)
            .ok_or_else(|| format!("not hex: {:?}", pair[0] as char))?;
        let low = (pair[1] as char)
            .to_digit(16)
            .ok_or_else(|| format!("not hex: {:?}", pair[1] as char))?;
        bytes.push(((high << 4) | low) as u8);
    }
    Ok(bytes)
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(protocol) = args.next() else {
        eprintln!("usage: decode-hex <atk|razer> <hex>");
        return ExitCode::from(64);
    };
    let Some(hex) = args.next() else {
        eprintln!("usage: decode-hex <atk|razer> <hex>");
        return ExitCode::from(64);
    };

    let bytes = match parse_hex(&hex) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(64);
        }
    };
    println!("input: {} bytes = {}", bytes.len(), hex);

    match protocol.as_str() {
        "atk" => {
            // The OS-reported report id is unknown when decoding a pasted
            // buffer, so pass the protocol id: a leading 0x08 is stripped
            // anyway, and a mismatching first byte is then rejected.
            match atk::decode(atk::REPORT_ID, &bytes) {
                None => {
                    println!("result: not an ATK battery report (ignored)");
                    ExitCode::from(1)
                }
                Some(Ok(reading)) => {
                    println!(
                        "result: battery={}% charging={}",
                        reading.battery, reading.charging
                    );
                    ExitCode::SUCCESS
                }
                Some(Err(error)) => {
                    println!("result: {}", describe(&error));
                    ExitCode::from(2)
                }
            }
        }
        "razer" => match razer::decode_battery(&bytes) {
            Ok(reading) => {
                println!("result: battery={}%", reading.battery);
                // Charging needs a second command, so report it separately.
                if let Ok(()) =
                    razer::validate_response(&bytes, razer::COMMAND_CLASS, razer::CHARGING_COMMAND)
                {
                    if let Some(charging) = razer::charging(&bytes) {
                        println!("        charging={charging}");
                    }
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                println!("result: {}", describe(&error));
                ExitCode::from(2)
            }
        },
        other => {
            eprintln!("unknown protocol {other:?}, expected \"atk\" or \"razer\"");
            ExitCode::from(64)
        }
    }
}

fn describe(error: &DecodeError) -> String {
    match error {
        DecodeError::Status(status) => {
            format!("{} (device returned status 0x{status:02x})", error.code())
        }
        DecodeError::Malformed(detail) => format!("{} ({detail})", error.code()),
        other => other.code().to_string(),
    }
}
