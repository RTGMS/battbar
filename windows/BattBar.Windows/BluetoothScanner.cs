using Microsoft.Win32;

namespace BattBar;

/// <summary>
/// Bluetooth mice, read from the battery property Windows keeps in the registry.
///
/// Whether a row counts as a mouse and whether the value is plausible is decided
/// by the core; this only walks the PnP tree.
/// </summary>
internal static class BluetoothScanner
{
    /// <summary>`{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2` – Bluetooth battery level.</summary>
    private static readonly Guid BatteryProperty =
        new("104ea319-6ee2-4701-bd47-8ddbf425bbe5");

    /// <summary>`{83DA6326-97A6-4088-9453-A1923F573B29} 15` – is present.</summary>
    private static readonly Guid PresentProperty =
        new("83da6326-97a6-4088-9453-a1923f573b29");

    internal static IEnumerable<DeviceOutcome> Scan()
    {
        var results = new List<DeviceOutcome>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // The battery property lives on the paired-device node, which is under
        // Enum\BTHLE and Enum\BTHENUM; walking both covers Classic and LE.
        foreach (string root in new[]
                 {
                     @"SYSTEM\CurrentControlSet\Enum\BTHLE\DEV",
                     @"SYSTEM\CurrentControlSet\Enum\BTHENUM\DEV",
                 })
        {
            using RegistryKey? devices = Registry.LocalMachine.OpenSubKey(root);
            if (devices is null)
            {
                continue;
            }

            foreach (string address in devices.GetSubKeyNames())
            {
                string[] instances;
                try
                {
                    using RegistryKey? node = devices.OpenSubKey(address);
                    if (node is null)
                    {
                        continue;
                    }
                    instances = node.GetSubKeyNames();
                }
                catch (System.Security.SecurityException)
                {
                    continue;
                }

                foreach (string instance in instances)
                {
                    string path = $@"{root}\{address}\{instance}";
                    string instanceId = path.Replace(@"SYSTEM\CurrentControlSet\Enum\", string.Empty);
                    if (!seen.Add(instanceId))
                    {
                        continue;
                    }

                    if (Read(path) is not { } row)
                    {
                        continue;
                    }

                    results.Add(row);
                }
            }
        }

        return results;
    }

    private static DeviceOutcome? Read(string keyPath)
    {
        using RegistryKey? key = Registry.LocalMachine.OpenSubKey(keyPath);
        if (key is null)
        {
            return null;
        }

        string name = key.GetValue("FriendlyName") as string
                      ?? key.GetValue("DeviceDesc") as string
                      ?? string.Empty;
        // Drop the "BTHENUM\..." style prefix and any leading '@'.
        int semicolon = name.LastIndexOf(';');
        if (semicolon >= 0)
        {
            name = name[(semicolon + 1)..];
        }
        name = name.TrimStart('@', '{');
        if (name.Length == 0)
        {
            return null;
        }

        byte[]? batteryRaw = Property(key, BatteryProperty, 2);
        byte[]? presentRaw = Property(key, PresentProperty, 15);
        if (batteryRaw is null)
        {
            return null;
        }

        int battery = BitConverter.ToInt32(batteryRaw, 0);
        bool? present = presentRaw is null ? null : BitConverter.ToInt32(presentRaw, 0) != 0;

        var attributes = new Dictionary<string, string>
        {
            ["device_batteryLevelMain"] = battery.ToString(),
        };
        (byte? level, _) = CoreBridge.BluetoothReadings(attributes);
        if (level is null)
        {
            return null;
        }

        if (!CoreBridge.IsLikelyMouse(name, "Mouse") && !CoreBridge.IsLikelyMouse(name, string.Empty))
        {
            return null;
        }
        if (present == false)
        {
            return null;
        }

        string instanceId = keyPath.Replace(@"SYSTEM\CurrentControlSet\Enum\", string.Empty);
        return new DeviceOutcome
        {
            Id = CoreBridge.WindowsBluetoothId(instanceId, name),
            Name = name,
            Subtitle = "Windows 蓝牙",
            Provider = ProviderKind.Bluetooth,
            Connection = ConnectionKind.Bluetooth,
            Source = "Windows 蓝牙",
            Battery = level,
            Charging = null,
        };
    }

    /// <summary>Read a device property blob by GUID + pid.</summary>
    private static byte[]? Property(RegistryKey key, Guid formatId, int propertyId)
    {
        foreach (string valueName in key.GetValueNames())
        {
            // Windows encodes device properties as "{GUID} {pid}".
            if (!valueName.StartsWith($"{{{formatId}}}", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            string[] parts = valueName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2 ||
                !int.TryParse(parts[1], out int parsed) ||
                parsed != propertyId)
            {
                continue;
            }

            return key.GetValue(valueName) as byte[];
        }
        return null;
    }
}
