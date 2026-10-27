using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// Paints the tray icon: a coloured tile showing the battery percentage.
///
/// The Windows notification area only shows an icon, so the number has to be in
/// the bitmap. Presentation only.
/// </summary>
internal static class BatteryIcon
{
    private const int Size = 32;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    /// <summary>Build an <see cref="Icon"/> and the handle the caller must release.</summary>
    internal static (Icon Icon, IntPtr Handle) Build(byte? level, bool charging)
    {
        using var bitmap = new Bitmap(Size, Size);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            graphics.Clear(Background(level, charging));

            string label = charging && level >= 100
                ? "AC"
                : level is { } value
                    ? Math.Min((int)value, 100).ToString()
                    : "--";

            using var font = new Font("Segoe UI", label.Length > 2 ? 9f : 12f, FontStyle.Bold,
                GraphicsUnit.Pixel);
            using var brush = new SolidBrush(Color.White);
            var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
            };
            graphics.DrawString(label, font, brush, new RectangleF(0, 0, Size, Size), format);
        }

        IntPtr handle = bitmap.GetHicon();
        return (Icon.FromHandle(handle), handle);
    }

    internal static void Release(IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            DestroyIcon(handle);
        }
    }

    private static Color Background(byte? level, bool charging)
    {
        if (charging)
        {
            return Color.FromArgb(0x8d, 0xe9, 0xd5);
        }
        return level switch
        {
            <= 20 => Color.FromArgb(0xff, 0x9a, 0x8b),
            <= 40 => Color.FromArgb(0xff, 0xc5, 0x71),
            null => Color.FromArgb(0x58, 0x60, 0x60),
            _ => Color.FromArgb(0x9b, 0xe8, 0xb8),
        };
    }

    /// <summary>Tooltip text: one line per device.</summary>
    internal static string Tooltip(IReadOnlyList<DeviceOutcome> devices)
    {
        if (devices.Count == 0)
        {
            return "电量栏 · 未发现鼠标";
        }
        return string.Join(Environment.NewLine,
            devices.Select(device => $"{device.Name}：{device.BatteryText()}"));
    }
}
