using System.Drawing;

namespace BattBar;

/// <summary>
/// Shared presentation helpers: the level colour used by the taskbar strip and
/// the tooltip wording (kept in step with the macOS status item).
/// </summary>
internal static class BatteryIcon
{
    /// <summary>Colour for a level: grey when unknown/stale, warm at low levels.</summary>
    internal static Color LevelColor(byte? level, bool charging)
    {
        if (charging && level is not null)
        {
            return Color.FromArgb(0x3f, 0xc1, 0xb0);
        }
        return level switch
        {
            null => Color.FromArgb(0x9a, 0xa0, 0xa6),
            <= 20 => Color.FromArgb(0xf2, 0x6d, 0x5f),
            <= 40 => Color.FromArgb(0xf5, 0xb5, 0x4c),
            _ => Color.FromArgb(0x6f, 0xd0, 0x8e),
        };
    }

    /// <summary>
    /// Tooltip text, worded the same way as the macOS status item: one line per
    /// device, with “上次读数” in front of a retained value.
    /// </summary>
    internal static string Tooltip(IReadOnlyList<DeviceOutcome> devices)
    {
        if (devices.Count == 0)
        {
            return "电量栏 · 未发现鼠标";
        }
        return string.Join(Environment.NewLine, devices.Select(device =>
        {
            string battery = device.Battery is { } level ? $"{level}%" : "--";
            string stale = device.Stale ? "上次读数 " : string.Empty;
            string charging = device.Charging == true ? "，充电中" : string.Empty;
            return $"{device.Name}：{stale}{battery}{charging}";
        }));
    }
}
