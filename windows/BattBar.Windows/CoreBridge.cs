using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// String-returning conveniences over <see cref="Core"/>.
///
/// Still marshalling only: the core produces the values, this allocates buffers
/// and reads them back.
/// </summary>
internal static class CoreBridge
{
    private const int BufferLength = 256;

    internal static (string Name, string Subtitle) AtkDisplayName(HidDevice device)
    {
        IntPtr product = Core.Alloc(device.Product ?? string.Empty);
        var name = new byte[BufferLength];
        var subtitle = new byte[BufferLength];
        try
        {
            Core.battbar_atk_display_name(product, name, (UIntPtr)name.Length,
                subtitle, (UIntPtr)subtitle.Length);
        }
        finally
        {
            Core.Free(product);
        }
        return (Utf8(name), Utf8(subtitle));
    }

    internal static string AtkDeviceId(HidDevice device)
    {
        IntPtr product = Core.Alloc(device.Product ?? string.Empty);
        IntPtr serial = Core.Alloc(device.SerialNumber ?? string.Empty);
        var buffer = new byte[BufferLength];
        try
        {
            Core.battbar_atk_device_id(device.VendorId, device.ProductId, serial, product,
                buffer, (UIntPtr)buffer.Length);
        }
        finally
        {
            Core.Free(product);
            Core.Free(serial);
        }
        return Utf8(buffer);
    }

    internal static (string Name, string Subtitle) RazerDisplayName(HidDevice device)
    {
        IntPtr product = Core.Alloc(device.Product ?? string.Empty);
        var name = new byte[BufferLength];
        var subtitle = new byte[BufferLength];
        try
        {
            Core.battbar_razer_display_name(product, device.ProductId, name, (UIntPtr)name.Length,
                subtitle, (UIntPtr)subtitle.Length);
        }
        finally
        {
            Core.Free(product);
        }
        return (Utf8(name), Utf8(subtitle));
    }

    internal static string RazerDeviceId(HidDevice device)
    {
        var buffer = new byte[BufferLength];
        Core.battbar_razer_device_id(device.VendorId, device.ProductId, buffer, (UIntPtr)buffer.Length);
        return Utf8(buffer);
    }

    internal static string WindowsBluetoothId(string instanceId, string name)
    {
        IntPtr instance = Core.Alloc(instanceId);
        IntPtr label = Core.Alloc(name);
        var buffer = new byte[BufferLength];
        try
        {
            Core.battbar_bluetooth_windows_id(instance, label, buffer, (UIntPtr)buffer.Length);
        }
        finally
        {
            Core.Free(instance);
            Core.Free(label);
        }
        return Utf8(buffer);
    }

    /// <summary>Battery/charging rules for a flattened PnP property set.</summary>
    internal static (byte? Battery, bool? Charging) BluetoothReadings(IReadOnlyDictionary<string, string> attributes)
    {
        int count = attributes.Count;
        var keys = new IntPtr[count];
        var values = new IntPtr[count];
        try
        {
            int index = 0;
            foreach (KeyValuePair<string, string> pair in attributes)
            {
                keys[index] = Core.Alloc(pair.Key);
                values[index] = Core.Alloc(pair.Value);
                index++;
            }

            int battery = Core.battbar_bluetooth_battery(count, keys, values);
            int charging = Core.battbar_bluetooth_charging(count, keys, values);
            return (
                battery >= 0 ? (byte)battery : null,
                charging switch { 1 => true, 0 => false, _ => (bool?)null });
        }
        finally
        {
            foreach (IntPtr pointer in keys) Core.Free(pointer);
            foreach (IntPtr pointer in values) Core.Free(pointer);
        }
    }

    internal static bool IsLikelyMouse(string name, string minorType)
    {
        IntPtr label = Core.Alloc(name);
        IntPtr type = Core.Alloc(minorType);
        try
        {
            return Core.battbar_bluetooth_is_likely_mouse(label, type) != 0;
        }
        finally
        {
            Core.Free(label);
            Core.Free(type);
        }
    }

    private static string Utf8(byte[] buffer)
    {
        int end = Array.IndexOf(buffer, (byte)0);
        return System.Text.Encoding.UTF8.GetString(buffer, 0, end < 0 ? buffer.Length : end);
    }
}

/// <summary>Merge policy and alert decisions, both owned by the core.</summary>
internal static class CoreDecisions
{
    /// <summary>Retention, ordering and the active device.</summary>
    internal static (List<DeviceOutcome> Devices, int ActiveIndex) Merge(
        IReadOnlyList<DeviceOutcome> fresh,
        IReadOnlyList<DeviceOutcome> previous,
        IReadOnlyList<ProviderKind> failed,
        string? selectedId)
    {
        var map = new List<DeviceOutcome>(fresh.Count + previous.Count);
        map.AddRange(fresh);
        map.AddRange(previous);

        IntPtr freshBuffer = BuildSummaries(fresh);
        IntPtr previousBuffer = BuildSummaries(previous);
        IntPtr selected = Core.Alloc(selectedId ?? string.Empty);
        int capacity = Math.Max(1, map.Count);
        IntPtr entries = Marshal.AllocHGlobal(Marshal.SizeOf<Core.MergedRef>() * capacity);
        try
        {
            int[] failedCodes = failed.Select(provider => (int)provider).ToArray();
            int status = Core.battbar_merge_scan(freshBuffer, fresh.Count, previousBuffer, previous.Count,
                failedCodes, failedCodes.Length, selected, entries, out int count, out int active);
            if (status != 0)
            {
                return (new List<DeviceOutcome>(fresh), 0);
            }

            var devices = new List<DeviceOutcome>(count);
            for (int index = 0; index < count; index++)
            {
                IntPtr slot = entries + index * Marshal.SizeOf<Core.MergedRef>();
                Core.MergedRef entry = Marshal.PtrToStructure<Core.MergedRef>(slot);
                // Fresh devices occupy the first block of `map`.
                int offset = entry.FromPrevious != 0 ? fresh.Count + entry.Index : entry.Index;
                if (offset < 0 || offset >= map.Count)
                {
                    continue;
                }
                DeviceOutcome device = map[offset];
                devices.Add(new DeviceOutcome
                {
                    Id = device.Id,
                    Name = device.Name,
                    Subtitle = device.Subtitle,
                    Provider = device.Provider,
                    Connection = device.Connection,
                    Source = device.Source,
                    Battery = device.Battery,
                    Charging = device.Charging,
                    Stale = entry.Stale != 0,
                });
            }
            return (devices, active);
        }
        finally
        {
            Marshal.FreeHGlobal(entries);
            Marshal.FreeHGlobal(freshBuffer);
            Marshal.FreeHGlobal(previousBuffer);
            Core.Free(selected);
        }
    }

    private static IntPtr BuildSummaries(IReadOnlyList<DeviceOutcome> devices)
    {
        int size = Marshal.SizeOf<Core.DeviceSummary>();
        IntPtr buffer = Marshal.AllocHGlobal(size * Math.Max(1, devices.Count));
        for (int index = 0; index < devices.Count; index++)
        {
            DeviceOutcome device = devices[index];
            var summary = new Core.DeviceSummary
            {
                Id = Core.Alloc(device.Id),
                Name = Core.Alloc(device.Name),
                Provider = (int)device.Provider,
                Connection = (int)device.Connection,
            };
            Marshal.StructureToPtr(summary, buffer + index * size, false);
        }
        return buffer;
    }

    /// <summary>Ask the core which devices need a notification.</summary>
    internal static List<(int Kind, string DeviceId, byte Battery)> Evaluate(
        IntPtr manager, IReadOnlyList<DeviceOutcome> devices, bool enabled)
    {
        var alerts = new List<(int, string, byte)>();
        if (manager == IntPtr.Zero || devices.Count == 0)
        {
            return alerts;
        }

        IntPtr ids = Marshal.AllocHGlobal(IntPtr.Size * devices.Count);
        IntPtr entries = Marshal.AllocHGlobal(Marshal.SizeOf<Core.AlertDevice>() * devices.Count);
        var kinds = new byte[devices.Count];
        try
        {
            for (int index = 0; index < devices.Count; index++)
            {
                DeviceOutcome device = devices[index];
                IntPtr id = Core.Alloc(device.Id);
                Marshal.WriteIntPtr(ids, index * IntPtr.Size, id);
                var entry = new Core.AlertDevice
                {
                    Id = id,
                    Battery = device.Battery ?? -1,
                    Charging = device.Charging switch { true => 1, false => 0, null => -1 },
                    Stale = device.Stale ? (byte)1 : (byte)0,
                };
                Marshal.StructureToPtr(entry, entries + index * Marshal.SizeOf<Core.AlertDevice>(), false);
            }

            int status = Core.battbar_alerts_evaluate(manager, entries, devices.Count,
                enabled ? (byte)1 : (byte)0, kinds);
            if (status != 0)
            {
                return alerts;
            }

            for (int index = 0; index < kinds.Length; index++)
            {
                if (kinds[index] != 0)
                {
                    alerts.Add((kinds[index], devices[index].Id, devices[index].Battery ?? 0));
                }
            }
            return alerts;
        }
        finally
        {
            for (int index = 0; index < devices.Count; index++)
            {
                Core.Free(Marshal.ReadIntPtr(ids, index * IntPtr.Size));
            }
            Marshal.FreeHGlobal(ids);
            Marshal.FreeHGlobal(entries);
        }
    }
}
