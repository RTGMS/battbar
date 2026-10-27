//! Shared battery normalisation helpers.

/// Clamp any signed value into a valid percentage.
///
/// The inherited Swift/JS behaviours differed slightly here (Swift clamps any
/// `Int`, JS rejects non-finite floats); the Rust core keeps the Swift
/// behaviour, which is what the shipped macOS app does today.
pub fn normalized_percent(raw: i64) -> u8 {
    raw.clamp(0, 100) as u8
}

/// Scale a 0...255 device value to a 0...100 percentage.
///
/// Used by the Razer protocol: `round(raw * 100 / 255)`.
pub fn scale_u8_percent(raw: u8) -> u8 {
    let scaled = (f64::from(raw) * 100.0 / 255.0).round();
    normalized_percent(scaled as i64)
}

/// Parse a battery percentage out of strings such as `"75%"`, `"75"` or
/// `"75 percent"`. Values outside `0..=100` are rejected rather than clamped,
/// matching the macOS Bluetooth parser. A leading `-` is rejected outright so
/// that `"-5%"` cannot be mistaken for `5`.
pub fn parse_percent_text(value: &str) -> Option<u8> {
    let trimmed = value.trim();
    if trimmed.starts_with('-') {
        return None;
    }
    let digits: String = trimmed
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        return None;
    }
    let parsed: u32 = digits.parse().ok()?;
    if parsed > 100 {
        return None;
    }
    Some(parsed as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_percentages() {
        assert_eq!(normalized_percent(-5), 0);
        assert_eq!(normalized_percent(250), 100);
        assert_eq!(normalized_percent(73), 73);
    }

    #[test]
    fn scales_razer_values() {
        assert_eq!(scale_u8_percent(0), 0);
        assert_eq!(scale_u8_percent(128), 50);
        assert_eq!(scale_u8_percent(255), 100);
        // The UI must never print "101%".
        assert_eq!(scale_u8_percent(254), 100);
    }

    #[test]
    fn parses_percent_text() {
        assert_eq!(parse_percent_text("75%"), Some(75));
        assert_eq!(parse_percent_text("75"), Some(75));
        assert_eq!(parse_percent_text("  42 percent"), Some(42));
        assert_eq!(parse_percent_text("101%"), None);
        assert_eq!(parse_percent_text("n/a"), None);
    }
}
