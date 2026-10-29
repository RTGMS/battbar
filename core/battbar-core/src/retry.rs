//! When to re-read after a dropped scan.
//!
//! A sleeping receiver misses the occasional query, and one extra attempt a few
//! seconds later usually lands. Retrying indefinitely would keep polling a mouse
//! that is asleep for hours, so the budget is a single retry per failed scan.
//!
//! Only the decision lives here: the timer itself belongs to each platform,
//! because macOS uses a `RunLoop` timer and Windows a `System.Windows.Forms`
//! one. Both call this so the policy cannot drift.

/// Delay before the single retry, in milliseconds.
pub const RETRY_DELAY_MS: u32 = 15_000;

/// Delay before the next attempt, or `None` when the next scheduled poll should
/// be the only remaining one.
///
/// * `has_stale` – the finished scan left at least one shown reading stale
/// * `already_retried` – the finished scan was itself the retry
pub fn retry_delay_ms(has_stale: bool, already_retried: bool) -> Option<u32> {
    if has_stale && !already_retried {
        Some(RETRY_DELAY_MS)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_scan_retries_once() {
        assert_eq!(retry_delay_ms(true, false), Some(RETRY_DELAY_MS));
    }

    #[test]
    fn the_retry_itself_does_not_retry_again() {
        assert_eq!(retry_delay_ms(true, true), None);
    }

    #[test]
    fn a_successful_scan_does_not_retry() {
        assert_eq!(retry_delay_ms(false, false), None);
        assert_eq!(retry_delay_ms(false, true), None);
    }
}
