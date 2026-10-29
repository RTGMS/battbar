//! BattBar protocol core.
//!
//! Everything in this crate is platform independent: it turns HID byte
//! sequences into battery readings and parses the text payloads that the
//! operating systems hand to us. The platform layers (`macos/` Swift and the
//! future `windows/` UI) only move bytes across the OS boundary and draw the
//! panel.
//!
//! Module map:
//!
//! * [`atk`] – ATK / VXE / MAD 2.4G receivers (Compx protocol, report 8).
//! * [`razer`] – Razer Viper V3 Pro / HyperPolling (90-byte feature report).
//! * [`bluetooth`] – battery records scraped from the OS.
//! * [`battery`] – percentage normalisation shared by all providers.
//! * [`alerts`] – low/critical notification de-duplication.
//! * [`merge`] – turning one scan into the ordered device list.
//! * [`retry`] – whether a dropped scan is worth one more attempt.
//!
//! The crate is `#![forbid(unsafe_code)]`; the C ABI lives in the separate
//! `battbar-ffi` crate so that the logic here stays trivially auditable.

#![forbid(unsafe_code)]
#![deny(missing_debug_implementations)]

pub mod alerts;
pub mod atk;
pub mod battery;
pub mod bluetooth;
pub mod merge;
pub mod razer;
pub mod retry;

/// A battery reading as exposed to the UI layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reading {
    /// Charge level clamped to `0..=100`.
    pub battery: u8,
    /// `true` when the device reports that it is charging.
    pub charging: bool,
}

/// Errors raised for a response that we recognised but could not accept.
///
/// Transport failures (open / write / timeout) stay in the platform layer,
/// because the error codes are OS specific.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// The device answered with a non-zero status byte.
    Status(u8),
    /// The response was cut short.
    TooShort,
    /// The response belongs to a different report id or command.
    NotForUs,
    /// The payload could not be interpreted.
    Malformed(&'static str),
}

impl DecodeError {
    /// Stable machine-readable code, mirrored by the C ABI.
    pub fn code(&self) -> &'static str {
        match self {
            DecodeError::Status(_) => "STATUS",
            DecodeError::TooShort => "TOO_SHORT",
            DecodeError::NotForUs => "NOT_FOR_US",
            DecodeError::Malformed(_) => "MALFORMED",
        }
    }
}

/// Minimal HID device description, as enumerated by the platform layer.
///
/// This is deliberately a plain struct rather than an OS handle: filtering
/// decisions belong to the core, opening the device belongs to the platform.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HidDeviceInfo {
    /// OS specific device path.
    pub path: String,
    pub vendor_id: u16,
    pub product_id: u16,
    /// `None` or empty when the device exposes no product string.
    pub product: Option<String>,
    pub serial_number: Option<String>,
    /// USB interface number, when the OS reports one.
    pub interface: Option<i32>,
    pub usage_page: Option<u16>,
    pub usage: Option<u16>,
}

impl HidDeviceInfo {
    pub(crate) fn product_str(&self) -> &str {
        self.product.as_deref().unwrap_or("")
    }

    pub(crate) fn serial_str(&self) -> &str {
        self.serial_number.as_deref().unwrap_or("").trim()
    }
}
