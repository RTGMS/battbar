using Microsoft.Win32.SafeHandles;

namespace BattBar;

/// <summary>Provider identity; the numeric values match the core's ABI.</summary>
internal enum ProviderKind
{
    Atk = 0,
    Razer = 1,
    Bluetooth = 2,
}

internal enum ConnectionKind
{
    Receiver = 0,
    Bluetooth = 1,
}

/// <summary>One device as the UI consumes it.</summary>
internal sealed class DeviceOutcome
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Subtitle { get; init; }
    public required ProviderKind Provider { get; init; }
    public required ConnectionKind Connection { get; init; }
    public required string Source { get; init; }
    public byte? Battery { get; set; }
    public bool? Charging { get; set; }
    public bool Stale { get; set; }

    public string BatteryText() => Battery is { } level ? $"{(Stale ? "~" : string.Empty)}{level}%" : "--";
}

internal sealed class ScanResult
{
    public List<DeviceOutcome> Devices { get; } = new();
    public List<string> Issues { get; } = new();
    public List<ProviderKind> Failed { get; } = new();
}

/// <summary>
/// Runs every provider. Selection, decoding and naming are core calls; this
/// file only opens handles and moves bytes.
/// </summary>
internal static class Providers
{
    private const int AtkReadTimeoutMs = 1200;
    private const int RazerCommandWaitMs = 70;
    private const int RazerAttempts = 5;

    internal static ScanResult ScanAll()
    {
        var result = new ScanResult();
        List<HidDevice> enumerated;
        try
        {
            enumerated = Hid.Enumerate();
        }
        catch (Exception error)
        {
            result.Issues.Add($"无法枚举 HID 设备：{error.Message}");
            return result;
        }

        Run(ProviderKind.Atk, result, () => ScanAtk(enumerated, result));
        Run(ProviderKind.Razer, result, () => ScanRazer(enumerated, result));
        Run(ProviderKind.Bluetooth, result, () => result.Devices.AddRange(BluetoothScanner.Scan()));
        return result;
    }

    private static void Run(ProviderKind kind, ScanResult result, Action action)
    {
        try
        {
            action();
        }
        catch (Exception error)
        {
            result.Issues.Add(error.Message);
            result.Failed.Add(kind);
        }
    }

    private static void ScanAtk(List<HidDevice> enumerated, ScanResult result)
    {
        foreach (HidDevice candidate in Select(enumerated, razer: false))
        {
            if (ReadAtk(candidate) is { } reading)
            {
                result.Devices.Add(new DeviceOutcome
                {
                    Id = CoreBridge.AtkDeviceId(candidate),
                    Name = CoreBridge.AtkDisplayName(candidate).Name,
                    Subtitle = CoreBridge.AtkDisplayName(candidate).Subtitle,
                    Provider = ProviderKind.Atk,
                    Connection = ConnectionKind.Receiver,
                    Source = "ATK HID",
                    Battery = reading.Battery,
                    Charging = reading.Charging,
                });
                return; // one receiver answers for one mouse
            }
        }
    }

    private static (byte Battery, bool Charging)? ReadAtk(HidDevice candidate)
    {
        using SafeFileHandle handle = Hid.Open(candidate.Path);
        if (handle.IsInvalid)
        {
            throw new InvalidOperationException("无法打开 ATK 接收器（可能被 ATK HUB 占用）");
        }

        int length = (int)(UIntPtr)Core.battbar_atk_request_len();
        var request = new byte[length];
        if (Core.battbar_atk_request(request, (UIntPtr)length) != length)
        {
            throw new InvalidOperationException("核心拒绝了 ATK 请求");
        }

        if (!Hid.Write(handle, request))
        {
            throw new InvalidOperationException("ATK 接收器拒绝写入指令");
        }

        var buffer = new byte[64];
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(AtkReadTimeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            int read = Hid.Read(handle, buffer, 200);
            if (read <= 0)
            {
                continue;
            }

            var slice = new byte[read];
            Array.Copy(buffer, slice, read);
            int status = Core.battbar_atk_decode(0x08, slice, (UIntPtr)read, out Core.Reading reading,
                out byte deviceStatus);
            if (status == Core.StatusOk)
            {
                return (reading.Battery, reading.Charging == 1);
            }
            if (status == Core.StatusNotForUs)
            {
                continue;
            }
            throw new InvalidOperationException($"ATK 设备返回状态 0x{deviceStatus:x2}");
        }

        throw new InvalidOperationException("ATK 接收器没有响应，请唤醒鼠标");
    }

    private static void ScanRazer(List<HidDevice> enumerated, ScanResult result)
    {
        foreach (HidDevice candidate in Select(enumerated, razer: true))
        {
            if (ReadRazer(candidate) is { } reading)
            {
                (string name, string subtitle) = CoreBridge.RazerDisplayName(candidate);
                result.Devices.Add(new DeviceOutcome
                {
                    Id = CoreBridge.RazerDeviceId(candidate),
                    Name = name,
                    Subtitle = subtitle,
                    Provider = ProviderKind.Razer,
                    Connection = ConnectionKind.Receiver,
                    Source = "Razer HID",
                    Battery = reading.Battery,
                    Charging = reading.Charging,
                });
                return;
            }
        }
    }

    private static (byte Battery, bool? Charging)? ReadRazer(HidDevice candidate)
    {
        using SafeFileHandle handle = Hid.Open(candidate.Path);
        if (handle.IsInvalid)
        {
            throw new InvalidOperationException("无法打开雷蛇接收器（可能被雷云占用）");
        }

        byte battery = WithRetries(() =>
        {
            byte[] response = Exchange(handle, 0x80);
            int status = Core.battbar_razer_decode_battery(response, (UIntPtr)response.Length,
                out Core.Reading reading);
            if (status != Core.StatusOk)
            {
                throw new InvalidOperationException("雷蛇电量数据不完整");
            }
            return reading.Battery;
        });

        bool? charging = null;
        try
        {
            charging = WithRetries(() =>
            {
                byte[] response = Exchange(handle, 0x84);
                int status = Core.battbar_razer_decode_charging(response, (UIntPtr)response.Length,
                    out Core.Reading reading);
                if (status != Core.StatusOk)
                {
                    throw new InvalidOperationException("雷蛇充电状态数据不完整");
                }
                return reading.Charging == 1;
            });
        }
        catch (InvalidOperationException)
        {
            // Charging is optional; keep the battery reading.
        }

        return (battery, charging);
    }

    private static byte[] Exchange(SafeFileHandle handle, byte commandId)
    {
        int length = (int)(UIntPtr)Core.battbar_razer_request_len();
        var report = new byte[length];
        if (Core.battbar_razer_request(0x07, commandId, report, (UIntPtr)length) != length)
        {
            throw new InvalidOperationException("核心拒绝了雷蛇请求");
        }

        // Windows expects the report id as byte 0 of a feature report.
        var framed = new byte[length + 1];
        Array.Copy(report, 0, framed, 1, length);
        if (!Hid.SetFeature(handle, framed))
        {
            throw new InvalidOperationException("雷蛇接收器拒绝写入 feature report");
        }

        Thread.Sleep(RazerCommandWaitMs);

        var response = new byte[length + 1];
        if (!Hid.GetFeature(handle, response))
        {
            throw new InvalidOperationException("雷蛇接收器没有返回 feature report");
        }
        return response;
    }

    private static T WithRetries<T>(Func<T> action)
    {
        Exception last = new InvalidOperationException("雷蛇设备没有响应");
        for (int attempt = 0; attempt < RazerAttempts; attempt++)
        {
            try
            {
                return action();
            }
            catch (Exception error)
            {
                last = error;
                Thread.Sleep(12);
            }
        }
        throw last;
    }

    private static List<HidDevice> Select(List<HidDevice> enumerated, bool razer)
    {
        using var array = new Core.HidInfoArray(enumerated);
        var indices = new int[8];
        int status = razer
            ? Core.battbar_razer_select(array.Pointer, array.Count, indices, indices.Length, out int count)
            : Core.battbar_atk_select(array.Pointer, array.Count, indices, indices.Length, out count);
        if (status != 0)
        {
            return new List<HidDevice>();
        }

        var picked = new List<HidDevice>(count);
        for (int index = 0; index < count; index++)
        {
            picked.Add(enumerated[indices[index]]);
        }
        return picked;
    }
}
