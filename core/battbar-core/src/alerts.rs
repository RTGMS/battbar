//! Low / critical battery notification decisions.
//!
//! The rules are shared so that the macOS panel, the Windows tray and any
//! future Linux client agree on *when* to notify. The text of the notification
//! stays in the platform layer, because it belongs to the UI language.
//!
//! Behaviour (identical to the shipped implementation):
//!
//! * below [`CRITICAL_THRESHOLD`] → one `Critical` alert, which also marks the
//!   low level as delivered so the user is not notified twice;
//! * below [`LOW_THRESHOLD`] → one `Low` alert;
//! * charging, or back above [`RESET_THRESHOLD`] → the device is re-armed;
//! * a device that disappears is forgotten, so a reconnect can alert again.

use std::collections::{HashMap, HashSet};

/// Alerts are sent once below this percentage.
pub const LOW_THRESHOLD: u8 = 20;
/// Alerts escalate once below this percentage.
pub const CRITICAL_THRESHOLD: u8 = 10;
/// Going above this percentage re-arms the alerts.
pub const RESET_THRESHOLD: u8 = 25;

/// The subset of a device that alerting cares about.
#[derive(Debug, Clone, Copy)]
pub struct AlertDevice<'a> {
    pub id: &'a str,
    pub battery: Option<u8>,
    pub charging: Option<bool>,
    /// Stale readings are shown to the user but never alerted on.
    pub stale: bool,
}

impl<'a> AlertDevice<'a> {
    pub fn new(id: &'a str, battery: Option<u8>) -> Self {
        Self {
            id,
            battery,
            charging: None,
            stale: false,
        }
    }
}

/// Which threshold was crossed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertKind {
    Low,
    Critical,
}

impl AlertKind {
    /// Stable identifier used by the platform layers to pick a localized title.
    pub fn key(&self) -> &'static str {
        match self {
            AlertKind::Low => "low",
            AlertKind::Critical => "critical",
        }
    }

    /// The threshold this alert represents.
    pub fn level(&self) -> u8 {
        match self {
            AlertKind::Low => LOW_THRESHOLD,
            AlertKind::Critical => CRITICAL_THRESHOLD,
        }
    }
}

/// One notification to deliver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert<'a> {
    pub kind: AlertKind,
    pub device_id: &'a str,
    pub battery: u8,
}

/// Remembers which thresholds were already announced for each device.
#[derive(Debug, Default)]
pub struct AlertManager {
    states: HashMap<String, HashSet<u8>>,
}

impl AlertManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Evaluate a scan result and return the alerts to deliver.
    ///
    /// Pass `enabled = false` when the user disabled notifications: the
    /// internal state is cleared and nothing is returned.
    pub fn evaluate<'a>(&mut self, devices: &[AlertDevice<'a>], enabled: bool) -> Vec<Alert<'a>> {
        let mut events = Vec::new();
        let mut active_ids: HashSet<&str> = HashSet::new();

        for device in devices {
            active_ids.insert(device.id);

            if !enabled || device.stale {
                continue;
            }
            let Some(battery) = device.battery else {
                continue;
            };

            if device.charging == Some(true) || battery > RESET_THRESHOLD {
                self.states.remove(device.id);
                continue;
            }

            let state = self.states.entry(device.id.to_string()).or_default();

            if battery <= CRITICAL_THRESHOLD {
                if !state.contains(&CRITICAL_THRESHOLD) {
                    state.insert(CRITICAL_THRESHOLD);
                    state.insert(LOW_THRESHOLD);
                    events.push(Alert {
                        kind: AlertKind::Critical,
                        device_id: device.id,
                        battery,
                    });
                }
            } else if battery <= LOW_THRESHOLD && !state.contains(&LOW_THRESHOLD) {
                state.insert(LOW_THRESHOLD);
                events.push(Alert {
                    kind: AlertKind::Low,
                    device_id: device.id,
                    battery,
                });
            }
        }

        // Forget devices that are no longer present so a reconnect can alert.
        self.states.retain(|id, _| active_ids.contains(id.as_str()));

        if !enabled {
            self.states.clear();
        }

        events
    }

    /// Forget every announced threshold (used when the user toggles alerts off).
    pub fn reset(&mut self) {
        self.states.clear();
    }

    /// Number of devices currently tracked; exposed for tests and diagnostics.
    pub fn tracked_devices(&self) -> usize {
        self.states.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(id: &str, battery: Option<u8>) -> AlertDevice<'_> {
        AlertDevice::new(id, battery)
    }

    #[test]
    fn alerts_once_below_the_low_threshold() {
        let mut manager = AlertManager::new();
        let low = device("a", Some(18));

        let first = manager.evaluate(&[low], true);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].kind, AlertKind::Low);
        assert_eq!(first[0].battery, 18);

        // Still low on the next scan: no repeat notification.
        assert!(manager.evaluate(&[low], true).is_empty());
    }

    #[test]
    fn escalates_to_critical_without_repeating_low() {
        let mut manager = AlertManager::new();
        assert_eq!(manager.evaluate(&[device("a", Some(18))], true).len(), 1);

        let critical = manager.evaluate(&[device("a", Some(8))], true);
        assert_eq!(critical.len(), 1);
        assert_eq!(critical[0].kind, AlertKind::Critical);

        // Neither threshold fires again while still critical.
        assert!(manager.evaluate(&[device("a", Some(7))], true).is_empty());
    }

    #[test]
    fn jumps_straight_to_critical() {
        let mut manager = AlertManager::new();
        let events = manager.evaluate(&[device("a", Some(5))], true);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, AlertKind::Critical);
    }

    #[test]
    fn re_arms_after_charging_or_recovery() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(15))], true);

        // Charging re-arms the device.
        let mut charging = device("a", Some(15));
        charging.charging = Some(true);
        assert!(manager.evaluate(&[charging], true).is_empty());
        assert_eq!(manager.tracked_devices(), 0);

        // Back to low again: notify again.
        assert_eq!(manager.evaluate(&[device("a", Some(15))], true).len(), 1);
    }

    #[test]
    fn recovers_above_the_reset_threshold() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(15))], true);
        assert!(manager.evaluate(&[device("a", Some(26))], true).is_empty());
        assert_eq!(manager.tracked_devices(), 0);
    }

    #[test]
    fn stays_armed_between_low_and_reset() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(15))], true);
        // 21..25 keeps the device tracked but does not re-alert.
        assert!(manager.evaluate(&[device("a", Some(22))], true).is_empty());
        assert!(manager.evaluate(&[device("a", Some(19))], true).is_empty());
    }

    #[test]
    fn ignores_stale_and_missing_readings() {
        let mut manager = AlertManager::new();

        let mut stale = device("a", Some(5));
        stale.stale = true;
        assert!(manager.evaluate(&[stale], true).is_empty());

        assert!(manager.evaluate(&[device("b", None)], true).is_empty());
    }

    #[test]
    fn forgets_disappeared_devices() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(18)), device("b", Some(18))], true);
        assert_eq!(manager.tracked_devices(), 2);

        manager.evaluate(&[device("a", Some(18))], true);
        assert_eq!(manager.tracked_devices(), 1);

        // Reconnecting device b alerts again.
        let events = manager.evaluate(&[device("a", Some(18)), device("b", Some(18))], true);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].device_id, "b");
    }

    #[test]
    fn disabled_alerts_stay_silent_and_clear_state() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(5))], true);
        assert!(manager.evaluate(&[device("a", Some(5))], false).is_empty());
        assert_eq!(manager.tracked_devices(), 0);

        // Re-enabling alerts fires again for a still-critical device.
        assert_eq!(manager.evaluate(&[device("a", Some(5))], true).len(), 1);
    }

    #[test]
    fn reset_forgets_everything() {
        let mut manager = AlertManager::new();
        manager.evaluate(&[device("a", Some(15))], true);
        manager.reset();
        assert_eq!(manager.tracked_devices(), 0);
        assert_eq!(manager.evaluate(&[device("a", Some(15))], true).len(), 1);
    }
}
