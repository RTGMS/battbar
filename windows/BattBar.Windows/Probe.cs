using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace BattBar;

/// <summary>
/// `BattBar.exe --probe`: print what the app sees, for hardware validation.
///
/// Mirrors the macOS `--probe` mode: the same providers are scanned, but the
/// result goes to stdout and to <c>%TEMP%\battbar-probe.txt</c> instead of the
/// tray. Runs before the single-instance mutex so it works while the app runs.
///
/// Every line is flushed as it is produced — a probe that hangs on one device
/// must still show how far it got.
/// </summary>
internal static class Probe
{
    private const uint AttachParentProcess = 0xFFFFFFFF;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    internal static string LogPath =>
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "battbar-probe.txt");

    internal static int Run()
    {
        var report = new Report();
        report.Line("BattBar Windows 探针");
        report.Line($"时间: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        report.Line($"系统: {Environment.OSVersion.VersionString}");
        report.Line($"进程: {Environment.ProcessPath}");

        // A WinExe has no console of its own; borrow the caller's when there is
        // one. Output also goes to the file, so a shortcut launch works.
        report.Line($"AttachConsole: {AttachConsole(AttachParentProcess)}");
        try
        {
            report.Line($"核心: 0x{Core.battbar_core_version():x8}");
        }
        catch (Exception error)
        {
            report.Line($"加载核心 DLL 失败: {error.Message}");
            return Finish(report, 1);
        }
        report.Line($"应用目录: {AppContext.BaseDirectory}");
        report.Line("核心原生库: battbar_ffi.dll（与应用同目录；单文件发布时随包解压）");
        report.Line();

        int exitCode = 0;
        try
        {
            using var watcher = new ShellRestartWatcher();
            report.Line($"Explorer 重启监听: handle=0x{watcher.Handle.ToInt64():x}");
        }
        catch (Exception error)
        {
            report.Line($"Explorer 重启监听不可用: {error.Message}");
        }

        List<HidDevice> devices;
        try
        {
            devices = Hid.Enumerate();
        }
        catch (Exception error)
        {
            report.Line($"无法枚举 HID 设备: {error}");
            return Finish(report, 1);
        }

        report.Line($"HID 设备: {devices.Count} 个 collection");
        foreach (HidDevice device in devices)
        {
            report.Line(
                $"  vid=0x{device.VendorId:x4} pid=0x{device.ProductId:x4}" +
                $" iface={Show(device.Interface)} page=0x{Show(device.UsagePage)}" +
                $" usage=0x{Show(device.Usage)}" +
                $" in={Show(device.InputReportByteLength)} out={Show(device.OutputReportByteLength)}" +
                $" feature={Show(device.FeatureReportByteLength)}" +
                $" product={Quote(device.Product)}");
            report.Line($"    path={device.Path}");
        }
        report.Line();

        report.Line("核心选出的 ATK 候选:");
        var atkCandidates = Providers.Candidates(razer: false, devices);
        foreach (HidDevice device in atkCandidates)
        {
            report.Line($"  iface={Show(device.Interface)} page=0x{Show(device.UsagePage)}" +
                        $" usage=0x{Show(device.Usage)} product={Quote(device.Product)}");
        }
        foreach (HidDevice device in atkCandidates)
        {
            try
            {
                (byte battery, bool charging) = Providers.ReadAtk(device,
                    line => report.Line($"    · {line}"));
                report.Line($"    = ATK 读取成功: {battery}% 充电={charging}");
            }
            catch (Exception error)
            {
                report.Line($"    = ATK 失败: {error.Message}");
            }
        }

        report.Line("核心选出的雷蛇候选:");
        var razerCandidates = Providers.Candidates(razer: true, devices);
        foreach (HidDevice device in razerCandidates)
        {
            report.Line($"  iface={Show(device.Interface)} page=0x{Show(device.UsagePage)}" +
                        $" usage=0x{Show(device.Usage)} feature=0x{Show(device.FeatureReportByteLength)}" +
                        $" product={Quote(device.Product)}");
        }
        foreach (HidDevice device in razerCandidates)
        {
            try
            {
                (byte battery, bool? charging) = Providers.ReadRazer(device,
                    line => report.Line($"    · {line}"));
                report.Line($"    = 雷蛇读取成功: {battery}% 充电={charging}");
            }
            catch (Exception error)
            {
                report.Line($"    = 雷蛇失败: {error.Message}");
            }
        }
        report.Line();

        report.Line("开始扫描…");
        Stopwatch stopwatch = Stopwatch.StartNew();
        ScanResult scan = Providers.ScanAll();
        stopwatch.Stop();

        Settings settings = Settings.Load();
        report.Line($"设置: 常驻电量条={(settings.ShowFloatingStrip ? "开" : "关")}，" +
                    $"隐藏设备={settings.HiddenDeviceIds.Count} 台，" +
                    $"刷新间隔={settings.RefreshInterval}s");
        report.Line($"一次扫描耗时: {stopwatch.ElapsedMilliseconds} ms");
        if (scan.Devices.Count == 0)
        {
            report.Line("结果: 未发现鼠标");
            exitCode = 1;
        }
        foreach (DeviceOutcome device in scan.Devices)
        {
            string charging = device.Charging switch
            {
                true => "充电中",
                false => "使用中",
                null => "未知",
            };
            string hidden = settings.IsHidden(device.Id) ? "（已隐藏，不显示在任务栏）" : string.Empty;
            report.Line(
                $"DEVICE: {device.Provider.ToString().ToLowerInvariant()} | {device.Name}" +
                $" | {device.BatteryText()} | {charging} | {device.Source}" +
                $" | stale={device.Stale.ToString().ToLowerInvariant()}{hidden}");
            report.Line($"  id={device.Id} subtitle={device.Subtitle}");
        }
        foreach (string issue in scan.Issues)
        {
            report.Line($"ISSUE: {issue}");
        }

        return Finish(report, exitCode);
    }

    private static int Finish(Report report, int exitCode)
    {
        report.Line();
        report.Line($"报告已写入: {LogPath}");
        return exitCode;
    }

    private static string Show(int? value) => value is { } number ? $"{number:x}" : "?";

    private static string Show(string? value) => value ?? "?";

    private static string Quote(string? value) => value is null ? "?" : $"\"{value}\"";

    /// <summary>Line buffer that appends to stdout and rewrites the log file.</summary>
    private sealed class Report
    {
        private readonly StringBuilder _text = new();

        internal void Line(string? line = null)
        {
            string value = line ?? string.Empty;
            _text.AppendLine(value);
            try
            {
                File.WriteAllText(LogPath, _text.ToString(), new UTF8Encoding(false));
            }
            catch (Exception)
            {
                // The log is best effort; stdout still has the same text.
            }
            try
            {
                Console.WriteLine(value);
            }
            catch (Exception)
            {
                // No console attached.
            }
        }
    }
}
