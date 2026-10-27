//! Turning one scan into the list the UI shows.
//!
//! Providers can fail independently: the ATK receiver may be waiting for the
//! mouse to wake up while Bluetooth is fine. Dropping every device on a partial
//! failure makes the panel flash empty, so a provider that failed keeps showing
//! its last reading, marked stale.
//!
//! The ordering is also policy, not presentation: receiver devices are more
//! informative than a Bluetooth mirror of the same mouse, so they come first.
//! Both rules used to live in the Swift app and, separately, in the Electron
//! main process; they live here now so the platforms cannot drift.

/// Which provider produced a device. The numeric values match the C ABI and the
/// Swift `DeviceProviderKind` ordering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Provider {
    Atk = 0,
    Razer = 1,
    Bluetooth = 2,
}

impl Provider {
    pub fn from_code(code: i32) -> Option<Provider> {
        match code {
            0 => Some(Provider::Atk),
            1 => Some(Provider::Razer),
            2 => Some(Provider::Bluetooth),
            _ => None,
        }
    }

    pub fn code(self) -> i32 {
        self as i32
    }
}

/// How the device is attached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Connection {
    Receiver,
    Bluetooth,
}

impl Connection {
    pub fn from_code(code: i32) -> Option<Connection> {
        match code {
            0 => Some(Connection::Receiver),
            1 => Some(Connection::Bluetooth),
            _ => None,
        }
    }

    pub fn code(self) -> i32 {
        match self {
            Connection::Receiver => 0,
            Connection::Bluetooth => 1,
        }
    }
}

/// The parts of a device the merge policy looks at.
#[derive(Debug, Clone, Copy)]
pub struct DeviceSummary<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub provider: Provider,
    pub connection: Connection,
}

/// Where a device in the merged list came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MergedRef {
    /// `true` when the entry refers to the `previous` slice.
    pub from_previous: bool,
    /// Index into that slice.
    pub index: usize,
    /// Reading is retained from an earlier scan.
    pub stale: bool,
}

/// Merge a scan result with the previous one and pick the active device.
///
/// * `fresh` – devices the providers returned this round
/// * `previous` – devices currently displayed
/// * `failed_providers` – providers that reported an issue this round
/// * `selected_id` – the user's saved choice, if any
///
/// A device is retained from `previous` only when its provider failed **and**
/// no fresh device covers that provider, which is what keeps the panel useful
/// while the receiver is asleep.
pub fn merge_scan(
    fresh: &[DeviceSummary<'_>],
    previous: &[DeviceSummary<'_>],
    failed_providers: &[Provider],
    selected_id: Option<&str>,
) -> (Vec<MergedRef>, Option<usize>) {
    let mut merged: Vec<MergedRef> = fresh
        .iter()
        .enumerate()
        .map(|(index, _)| MergedRef {
            from_previous: false,
            index,
            stale: false,
        })
        .collect();

    for (index, device) in previous.iter().enumerate() {
        if !failed_providers.contains(&device.provider) {
            continue;
        }
        let covered = fresh
            .iter()
            .any(|candidate| candidate.provider == device.provider);
        if covered {
            continue;
        }
        merged.push(MergedRef {
            from_previous: true,
            index,
            stale: true,
        });
    }

    // Sort by the policy above. `sort_by` is stable, which keeps provider order
    // for otherwise-equal devices.
    merged.sort_by(|left, right| {
        let left_device = resolve(*left, fresh, previous);
        let right_device = resolve(*right, fresh, previous);
        left_device
            .provider
            .cmp(&right_device.provider)
            .then_with(|| {
                connection_rank(left_device.connection)
                    .cmp(&connection_rank(right_device.connection))
            })
            .then_with(|| left_device.name.cmp(right_device.name))
    });

    let active = selected_id.and_then(|wanted| {
        merged
            .iter()
            .position(|entry| resolve(*entry, fresh, previous).id == wanted)
    });
    let active = active.or(if merged.is_empty() { None } else { Some(0) });

    (merged, active)
}

fn connection_rank(connection: Connection) -> u8 {
    match connection {
        Connection::Receiver => 0,
        Connection::Bluetooth => 1,
    }
}

fn resolve<'a>(
    entry: MergedRef,
    fresh: &'a [DeviceSummary<'a>],
    previous: &'a [DeviceSummary<'a>],
) -> DeviceSummary<'a> {
    if entry.from_previous {
        previous[entry.index]
    } else {
        fresh[entry.index]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device<'a>(
        id: &'a str,
        name: &'a str,
        provider: Provider,
        connection: Connection,
    ) -> DeviceSummary<'a> {
        DeviceSummary {
            id,
            name,
            provider,
            connection,
        }
    }

    #[test]
    fn sorts_by_provider_then_connection_then_name() {
        let fresh = [
            device(
                "bt1",
                "MX Master",
                Provider::Bluetooth,
                Connection::Bluetooth,
            ),
            device("atk2", "VXE R1", Provider::Atk, Connection::Receiver),
            device("atk1", "ATK Z1", Provider::Atk, Connection::Receiver),
            device("rz1", "Viper", Provider::Razer, Connection::Receiver),
        ];
        let (merged, active) = merge_scan(&fresh, &[], &[], None);
        let names: Vec<&str> = merged.iter().map(|entry| fresh[entry.index].name).collect();
        assert_eq!(names, ["ATK Z1", "VXE R1", "Viper", "MX Master"]);
        assert_eq!(active, Some(0));
        assert!(merged.iter().all(|entry| !entry.stale));
    }

    #[test]
    fn retains_last_reading_when_a_provider_fails() {
        let previous = [
            device("atk1", "ATK 无线鼠标", Provider::Atk, Connection::Receiver),
            device(
                "bt1",
                "MX Master",
                Provider::Bluetooth,
                Connection::Bluetooth,
            ),
        ];
        let fresh = [device(
            "bt1",
            "MX Master",
            Provider::Bluetooth,
            Connection::Bluetooth,
        )];

        let (merged, active) = merge_scan(&fresh, &previous, &[Provider::Atk], None);
        assert_eq!(merged.len(), 2);
        let retained = merged.iter().find(|entry| entry.from_previous).unwrap();
        assert!(retained.stale, "the retained device must be marked stale");
        assert_eq!(previous[retained.index].id, "atk1");
        // ATK has the highest priority, so the retained device is still first.
        assert_eq!(active, Some(0));
    }

    #[test]
    fn drops_the_retained_device_once_the_provider_recovers() {
        let previous = [device("atk1", "ATK", Provider::Atk, Connection::Receiver)];
        let fresh = [device("atk1", "ATK", Provider::Atk, Connection::Receiver)];
        let (merged, _) = merge_scan(&fresh, &previous, &[], None);
        assert_eq!(merged.len(), 1);
        assert!(!merged[0].stale);
    }

    #[test]
    fn keeps_the_users_selection() {
        let fresh = [
            device("atk1", "A", Provider::Atk, Connection::Receiver),
            device("bt1", "B", Provider::Bluetooth, Connection::Bluetooth),
        ];
        let (_, active) = merge_scan(&fresh, &[], &[], Some("bt1"));
        assert_eq!(active, Some(1));
    }

    #[test]
    fn falls_back_to_the_first_device() {
        let fresh = [
            device("atk1", "A", Provider::Atk, Connection::Receiver),
            device("bt1", "B", Provider::Bluetooth, Connection::Bluetooth),
        ];
        let (_, active) = merge_scan(&fresh, &[], &[], Some("gone"));
        assert_eq!(active, Some(0));

        let (empty, none) = merge_scan(&[], &[], &[], None);
        assert!(empty.is_empty());
        assert_eq!(none, None);
    }
}
