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
    private const int AtkReadSliceMs = 200;
    private const int RazerCommandWaitMs = 70;
    private const int RazerAttempts = 5;
    /// <summary>Razer status bytes worth explaining (0x02 ok, 0x01 busy).</summary>
    private const int RazerStatusFailure = 0x03;
    private const int RazerStatusTimeout = 0x04;
    private const int RazerStatusUnsupported = 0x05;
    /// <summary>Fallback input-report size when the OS reports none (ATK).</summary>
    private const int DefaultInputReportLength = 64;

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

    /// <summary>
    /// Try every candidate the core ranked until one answers. A receiver exposes
    /// several collections and only one of them speaks the protocol, so a
    /// failure on the first one must not abort the whole scan.
    /// </summary>
    private static void ScanAtk(List<HidDevice> enumerated, ScanResult result)
    {
        List<HidDevice> candidates = Select(enumerated, razer: false);
        // Report the best-ranked candidate's failure: the later collections are
        // known not to carry the protocol, so their errors only mislead.
        string? firstError = null;
        foreach (HidDevice candidate in candidates)
        {
            try
            {
                (byte battery, bool charging) = ReadAtk(candidate);
                (string name, string subtitle) = CoreBridge.AtkDisplayName(candidate);
                result.Devices.Add(new DeviceOutcome
                {
                    Id = CoreBridge.AtkDeviceId(candidate),
                    Name = name,
                    Subtitle = subtitle,
                    Provider = ProviderKind.Atk,
                    Connection = ConnectionKind.Receiver,
                    Source = "ATK HID",
                    Battery = battery,
                    Charging = charging,
                });
                return; // one receiver answers for one mouse
            }
            catch (Exception error)
            {
                firstError ??= error.Message;
            }
        }

        if (candidates.Count > 0)
        {
            // Tell the merge policy this provider failed, so the previous
            // reading is retained as stale (`~100%`) instead of the device
            // vanishing while the mouse sleeps.
            result.Failed.Add(ProviderKind.Atk);
            result.Issues.Add(firstError ?? "ATK 接收器没有响应，请唤醒鼠标");
        }
    }

    internal static (byte Battery, bool Charging) ReadAtk(HidDevice candidate,
        Action<string>? trace = null)
    {
        using SafeFileHandle handle = Hid.Open(candidate.Path);
        if (handle.IsInvalid)
        {
            throw new InvalidOperationException("无法打开 ATK 接收器（可能被 ATK HUB 占用）");
        }
        trace?.Invoke($"opened iface={candidate.Interface} page=0x{candidate.UsagePage:x}" +
                      $" usage=0x{candidate.Usage:x} in={candidate.InputReportByteLength}" +
                      $" out={candidate.OutputReportByteLength}");

        int length = (int)(UIntPtr)Core.battbar_atk_request_len();
        var request = new byte[length];
        if (Core.battbar_atk_request(request, (UIntPtr)length) != length)
        {
            throw new InvalidOperationException("核心拒绝了 ATK 请求");
        }

        // Windows requires the whole declared report: a 17-byte buffer on a
        // collection whose output report is 181 bytes fails with
        // ERROR_INVALID_PARAMETER (captured on an RS7 Air receiver).
        int outputLength = Math.Max(length, candidate.OutputReportByteLength ?? 0);
        byte[] report = request;
        if (outputLength > length)
        {
            report = new byte[outputLength];
            Array.Copy(request, report, length);
        }

        IoResult write = Hid.Write(handle, report);
        trace?.Invoke($"write {report.Length}B -> ok={write.Ok} bytes={write.Bytes} err={write.Error}");
        if (!write.Ok)
        {
            throw new InvalidOperationException(
                $"ATK 接收器拒绝写入指令（{Hid.DescribeError(write.Error)}）");
        }

        // Size the buffer from the report descriptor: this receiver answers with
        // a 385-byte report, so a fixed 64-byte buffer never completed a read.
        int bufferLength = Math.Max(DefaultInputReportLength, candidate.InputReportByteLength ?? 0);
        var buffer = new byte[bufferLength];
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(AtkReadTimeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            IoResult read = Hid.Read(handle, buffer, AtkReadSliceMs);
            trace?.Invoke($"read -> ok={read.Ok} bytes={read.Bytes} err={read.Error}");
            if (!read.Ok)
            {
                throw new InvalidOperationException($"读取 ATK 应答失败（{Hid.DescribeError(read.Error)}）");
            }
            if (read.Bytes <= 0)
            {
                continue;
            }

            var slice = new byte[read.Bytes];
            Array.Copy(buffer, slice, read.Bytes);
            // The report id is a core constant; never hard-code it here.
            int status = Core.battbar_atk_decode((byte)Core.battbar_atk_report_id(), slice,
                (UIntPtr)read.Bytes, out Core.Reading reading, out byte deviceStatus);
            trace?.Invoke($"decode status={status} device=0x{deviceStatus:x2}" +
                          $" first={Convert.ToHexString(slice, 0, Math.Min(8, slice.Length))}");
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
        List<HidDevice> candidates = Select(enumerated, razer: true);
        string? firstError = null;
        foreach (HidDevice candidate in candidates)
        {
            try
            {
                (byte battery, bool? charging) = ReadRazer(candidate);
                (string name, string subtitle) = CoreBridge.RazerDisplayName(candidate);
                result.Devices.Add(new DeviceOutcome
                {
                    Id = CoreBridge.RazerDeviceId(candidate),
                    Name = name,
                    Subtitle = subtitle,
                    Provider = ProviderKind.Razer,
                    Connection = ConnectionKind.Receiver,
                    Source = "Razer HID",
                    Battery = battery,
                    Charging = charging,
                });
                return;
            }
            catch (Exception error)
            {
                firstError ??= error.Message;
            }
        }

        if (candidates.Count > 0)
        {
            // Same as ATK: a sleeping mouse must keep its last reading.
            result.Failed.Add(ProviderKind.Razer);
            result.Issues.Add(firstError ?? "雷蛇接收器没有响应，请唤醒鼠标");
        }
    }

    internal static (byte Battery, bool? Charging) ReadRazer(HidDevice candidate,
        Action<string>? trace = null)
    {
        using SafeFileHandle handle = Hid.OpenForFeature(candidate.Path, out int openError);
        if (handle.IsInvalid)
        {
            throw new InvalidOperationException($"无法打开雷蛇接收器（{Hid.DescribeError(openError)}）");
        }
        trace?.Invoke($"opened iface={candidate.Interface} page=0x{candidate.UsagePage:x}" +
                      $" usage=0x{candidate.Usage:x} feature={candidate.FeatureReportByteLength}");

        byte battery = WithRetries(() =>
        {
            byte[] response = Exchange(handle, candidate, 0x80, trace);
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
                byte[] response = Exchange(handle, candidate, 0x84, trace);
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

    private static byte[] Exchange(SafeFileHandle handle, HidDevice candidate, byte commandId,
        Action<string>? trace)
    {
        int reportLength = (int)(UIntPtr)Core.battbar_razer_request_len();
        var report = new byte[reportLength];
        // The command class is a core constant too.
        int written = Core.battbar_razer_request((byte)Core.battbar_razer_command_class(), commandId,
            report, (UIntPtr)reportLength);
        if (written != reportLength)
        {
            throw new InvalidOperationException("核心拒绝了雷蛇请求");
        }

        // Windows expects the report id as byte 0 of a feature report, and the
        // buffer must be exactly the declared feature-report length.
        int featureLength = Math.Max(reportLength + 1, candidate.FeatureReportByteLength ?? 0);
        var framed = new byte[featureLength];
        Array.Copy(report, 0, framed, 1, Math.Min(reportLength, featureLength - 1));
        IoResult set = Hid.SetFeature(handle, framed);
        trace?.Invoke($"feature set cmd=0x{commandId:x2} len={featureLength}" +
                      $" -> ok={set.Ok} err={set.Error}");
        if (!set.Ok)
        {
            throw new InvalidOperationException(
                $"雷蛇接收器拒绝写入 feature report（{Hid.DescribeError(set.Error)}）");
        }

        Thread.Sleep(RazerCommandWaitMs);

        var response = new byte[featureLength];
        IoResult get = Hid.GetFeature(handle, response);
        trace?.Invoke($"feature get cmd=0x{commandId:x2} -> ok={get.Ok} err={get.Error}" +
                      $" first={Convert.ToHexString(response, 0, Math.Min(10, response.Length))}");
        if (!get.Ok)
        {
            throw new InvalidOperationException(
                $"雷蛇接收器没有返回 feature report（{Hid.DescribeError(get.Error)}）");
        }

        // The status byte is a protocol value: the core reads it, this only
        // turns the well-known failures into something a user can act on.
        int deviceStatus = Core.battbar_razer_status(response, (UIntPtr)response.Length);
        trace?.Invoke($"status=0x{deviceStatus:x2}");
        switch (deviceStatus)
        {
            case RazerStatusTimeout:
                throw new InvalidOperationException("雷蛇鼠标没有应答（可能已休眠，请动一下鼠标）");
            case RazerStatusFailure:
                throw new InvalidOperationException("雷蛇设备报告命令失败（0x03）");
            case RazerStatusUnsupported:
                throw new InvalidOperationException("雷蛇设备不支持该命令（0x05）");
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

    /// <summary>The collections the core picked for a provider, best first.</summary>
    internal static List<HidDevice> Candidates(bool razer, List<HidDevice> devices) =>
        Select(devices, razer);

    private static List<HidDevice> Select(List<HidDevice> enumerated, bool razer)
    {
        using var array = new Core.HidInfoArray(enumerated);
        var indices = new int[16];
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
