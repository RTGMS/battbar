using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// Always-visible battery text docked inside the taskbar, just left of the
/// notification area.
///
/// The Windows tray only shows a 16 px icon, so the readings had no visible
/// text anywhere: the user had to hover the icon to learn the level. This is a
/// layered window that renders the text straight onto the taskbar — no card, no
/// border — with one line per visible device. Clicking it opens the tray menu;
/// dragging moves it and the position is remembered.
///
/// It hides itself while another app is fullscreen or while the taskbar is
/// auto-hidden, which is where a top-most window would otherwise float.
/// </summary>
internal sealed class BatteryStrip : Form
{
    private const int WsExNoActivate = 0x0800_0000;
    private const int WsExToolWindow = 0x0000_0080;
    private const int WsExLayered = 0x0008_0000;
    private const int DragThreshold = 4;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoSize = 0x0001;
    private const int HwndTopmost = -1;

    private readonly List<DeviceOutcome> _devices = new();
    private readonly System.Windows.Forms.Timer _watchTimer;
    private Font? _nameFont;
    private Font? _valueFont;
    private int _dpi = 96;
    private Color _textColor = Color.FromArgb(0xf0, 0xf0, 0xf0);
    private Color _mutedColor = Color.FromArgb(0x9a, 0xa0, 0xa6);
    private string? _lastKey;

    private bool _dragging;
    private bool _movedSincePress;
    private bool _anyHidden;
    private Point _pressPoint;
    private Point _pressLocation;
    private Point? _savedPosition;
    /// <summary>Last taskbar geometry the strip laid itself out for.</summary>
    private string? _geometryKey;
    /// <summary>True while hidden because a fullscreen app or the shell hides us.</summary>
    private bool _suppressed;

    // Metrics computed by Relayout and reused while drawing.
    private int _padding = 4;
    private int _gap = 6;
    private int _rowHeight = 17;
    private int _rowsShown;
    private int _overflow;
    private int _batteryHeight = 15;
    private int _batteryWidth = 40;
    private int _batteryTextPad = 3;
    private int _batteryCapGap = 2;
    private int _batteryCapWidth = 3;
    private int _boltWidth;
    private int _valueWidth;

    internal BatteryStrip()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        DoubleBuffered = true;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Visible = false;

        // The taskbar is top-most too and raises itself whenever it is hovered
        // or clicked; re-assert the z-order, and notice fullscreen apps and an
        // auto-hidden taskbar (where a floating strip would be wrong).
        _watchTimer = new System.Windows.Forms.Timer { Interval = 600 };
        _watchTimer.Tick += (_, _) => Watch();
    }

    /// <summary>Raised when the strip is clicked (opens the tray menu).</summary>
    internal event EventHandler? Clicked;

    /// <summary>Raised after the user dragged the strip, with its new position.</summary>
    internal event EventHandler<Point>? Moved;

    /// <summary>Position remembered from the last session, if any.</summary>
    internal Point? SavedPosition
    {
        get => _savedPosition;
        set
        {
            if (value is { } point && IsOnScreen(point))
            {
                _savedPosition = point;
                Location = point;
            }
            else
            {
                _savedPosition = null;
            }
        }
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WsExNoActivate | WsExToolWindow | WsExLayered;
            return parameters;
        }
    }

    /// <summary>Replace the shown rows and resize / reposition the strip.</summary>
    internal void UpdateContent(IReadOnlyList<DeviceOutcome> devices, bool anyHidden)
    {
        _devices.Clear();
        _devices.AddRange(devices);
        _anyHidden = anyHidden;

        string key = string.Join("|", _devices.Select(device =>
            $"{device.Id}={device.BatteryText()}/{device.Charging}")) + (anyHidden ? "#hidden" : string.Empty);
        if (key == _lastKey && Visible)
        {
            return;
        }
        _lastKey = key;

        Relayout();
        if (!_suppressed)
        {
            if (!Visible)
            {
                Show();
                _watchTimer.Start();
            }
            RenderLayered();
        }
    }

    internal void HideStrip()
    {
        _watchTimer.Stop();
        _lastKey = null;
        _suppressed = false;
        Hide();
    }

    /// <summary>Forget a dragged position and dock next to the tray again.</summary>
    internal void ResetPosition()
    {
        _savedPosition = null;
        Relayout();
        if (Visible)
        {
            RenderLayered();
        }
    }

    /// <summary>Re-assert z-order; hide while a fullscreen app or the shell wins.</summary>
    private void Watch()
    {
        bool blocked = IsFullscreenForeground() || !IsTaskbarShown();
        if (blocked)
        {
            if (Visible)
            {
                _suppressed = true;
                Hide();
            }
            return;
        }

        // The taskbar can move, change height, move to another edge, or the DPI
        // can change while we sit still: re-layout when its geometry moved.
        string geometry = GeometryKey();
        if (geometry != _geometryKey)
        {
            _geometryKey = geometry;
            Relayout();
            if (Visible)
            {
                RenderLayered();
            }
            return;
        }

        if (_suppressed)
        {
            _suppressed = false;
            if (!Visible && (_devices.Count > 0 || _lastKey is not null))
            {
                Show();
                RenderLayered();
            }
            return;
        }

        RaiseAboveTaskbar();
    }

    /// <summary>Cheap signature of the layout inputs, used to detect taskbar changes.</summary>
    private string GeometryKey() =>
        (TryGetTaskbar(out Rectangle taskbar, out _, out _) ? taskbar.ToString() : "none")
        + "/" + DeviceDpi;

    /// <summary>Keep the strip above the taskbar without taking focus.</summary>
    private void RaiseAboveTaskbar()
    {
        if (!Visible || Handle == IntPtr.Zero)
        {
            return;
        }
        SetWindowPos(Handle, new IntPtr(HwndTopmost), 0, 0, 0, 0,
            SwpNoMove | SwpNoSize | SwpNoActivate);
    }

    /// <summary>Whether an app other than the shell owns the whole monitor.</summary>
    private static bool IsFullscreenForeground()
    {
        IntPtr foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero)
        {
            return false;
        }

        var builder = new char[64];
        GetClassName(foreground, builder, builder.Length);
        string className = new(builder);
        if (className is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Windows.UI.Core.CoreWindow")
        {
            return false;
        }

        if (!GetWindowRect(foreground, out Rect rect))
        {
            return false;
        }

        Rectangle window = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        foreach (Screen screen in Screen.AllScreens)
        {
            Rectangle bounds = screen.Bounds;
            if (window.Left <= bounds.Left && window.Top <= bounds.Top &&
                window.Right >= bounds.Right && window.Bottom >= bounds.Bottom)
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>False while the taskbar is auto-hidden (slid off the screen).</summary>
    private static bool IsTaskbarShown()
    {
        IntPtr handle = FindWindow("Shell_TrayWnd", null);
        if (handle == IntPtr.Zero || !IsWindowVisible(handle) || !GetWindowRect(handle, out Rect rect))
        {
            return false;
        }

        Rectangle taskbar = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        Rectangle screen = Screen.FromRectangle(taskbar).Bounds;
        Rectangle overlap = Rectangle.Intersect(taskbar, screen);
        if (overlap.Width <= 0 || overlap.Height <= 0)
        {
            return false;
        }

        // A horizontal taskbar that slid down still shows only a sliver.
        return taskbar.Width >= taskbar.Height
            ? overlap.Height >= taskbar.Height / 2
            : overlap.Width >= taskbar.Width / 2;
    }

    /// <summary>Recreate the fonts after a DPI change.</summary>
    private void EnsureFonts()
    {
        int dpi = DeviceDpi;
        if (_nameFont is not null && dpi == _dpi)
        {
            return;
        }

        _dpi = dpi;
        _nameFont?.Dispose();
        _valueFont?.Dispose();
        float em = 9f * dpi / 96f;
        _nameFont = new Font("Segoe UI", em, FontStyle.Regular, GraphicsUnit.Point);
        _valueFont = new Font("Segoe UI", em, FontStyle.Bold, GraphicsUnit.Point);
    }

    private int Scaled(int value) => (int)Math.Round(value * _dpi / 96.0);

    /// <summary>
    /// Size the window to its rows, shrinking the rows so the strip stays
    /// inside the taskbar band; devices that still do not fit collapse into a
    /// “+N” line.
    /// </summary>
    private void Relayout()
    {
        EnsureFonts();

        bool haveTaskbar = TryGetTaskbar(out Rectangle taskbar, out _, out _);
        bool horizontal = !haveTaskbar || taskbar.Width >= taskbar.Height;
        int available = haveTaskbar ? taskbar.Height - Scaled(2) : 0;
        int widthLimit = haveTaskbar && !horizontal ? taskbar.Width - Scaled(4) : 0;

        _padding = Scaled(4);
        _gap = Scaled(6);
        _rowHeight = Scaled(17);
        _rowsShown = Math.Max(1, _devices.Count);
        _overflow = 0;

        if (available > 0 && _devices.Count > 0)
        {
            // Fit the rows into the taskbar, then reserve one row for “+N”.
            while (Fits(available) is false)
            {
                if (_rowHeight > Scaled(13))
                {
                    _rowHeight = Math.Max(Scaled(13), _rowHeight - 1);
                }
                else if (_padding > Scaled(2))
                {
                    _padding = Math.Max(Scaled(2), _padding - 1);
                }
                else
                {
                    _rowsShown--;
                    if (_rowsShown < 1)
                    {
                        _rowsShown = 1;
                        break;
                    }
                }
            }

            if (_rowsShown < _devices.Count)
            {
                // Take one more slot off the devices for the counter row, when
                // that still leaves at least one device visible.
                _rowsShown = Math.Max(1, _rowsShown - 1);
                _overflow = _devices.Count - _rowsShown;
                while (Fits(available) is false && _rowsShown > 1)
                {
                    _rowsShown--;
                    _overflow = _devices.Count - _rowsShown;
                }
            }
        }

        int nameWidth = 0;
        int valueWidth = 0;
        string emptyText = _anyHidden ? "已隐藏全部设备" : "未发现鼠标";
        if (_devices.Count == 0)
        {
            nameWidth = TextRenderer.MeasureText(emptyText, _nameFont).Width;
        }
        bool anyCharging = false;
        foreach (DeviceOutcome device in _devices.Take(Math.Max(1, _rowsShown)))
        {
            nameWidth = Math.Max(nameWidth, TextRenderer.MeasureText(device.Name, _nameFont).Width);
            valueWidth = Math.Max(valueWidth,
                TextRenderer.MeasureText(device.BatteryText(), _valueFont).Width);
            anyCharging |= device.Charging == true;
        }
        if (_overflow > 0)
        {
            nameWidth = Math.Max(nameWidth,
                TextRenderer.MeasureText($"+{_overflow} 台", _nameFont).Width);
        }
        nameWidth = Math.Min(nameWidth, horizontal ? Scaled(170) : Scaled(120));

        // The menu bar item on macOS is "name [battery with the number inside]";
        // the same geometry is used here, one row per device.
        _batteryTextPad = Math.Max(2, Scaled(3));
        _batteryCapGap = Math.Max(1, Scaled(2));
        _batteryCapWidth = Math.Max(2, Scaled(3));
        _batteryHeight = Math.Max(Scaled(10), Math.Min(_rowHeight - 2, Scaled(15)));
        _boltWidth = anyCharging ? Math.Max(4, Scaled(6)) : 0;
        _valueWidth = valueWidth;
        _batteryWidth = _devices.Count > 0
            ? valueWidth + _boltWidth + _batteryTextPad * 2 + _batteryCapGap + _batteryCapWidth
            : 0;

        int width = _padding * 2 + nameWidth;
        if (_batteryWidth > 0)
        {
            width += _gap * 2 + _batteryWidth;
        }
        if (widthLimit > 0)
        {
            width = Math.Min(width, widthLimit);
        }

        int rows = Math.Max(1, _rowsShown + (_overflow > 0 ? 1 : 0));
        int height = _padding * 2 + rows * _rowHeight;
        if (available > 0)
        {
            height = Math.Min(height, available);
        }

        if (Width != width || Height != height)
        {
            Size = new Size(width, height);
        }

        if (_savedPosition is null)
        {
            DockToTaskbar();
        }
        _textColor = SampleTextColor(haveTaskbar, horizontal);
        _mutedColor = Color.FromArgb(150, _textColor);
        RaiseAboveTaskbar();
    }

    /// <summary>Whether the device rows plus a possible counter row fit.</summary>
    private bool Fits(int available) =>
        _padding * 2 + (_rowsShown + (_rowsShown < _devices.Count ? 1 : 0)) * _rowHeight <= available;

    /// <summary>Pick a text colour that reads on the actual taskbar.</summary>
    private Color SampleTextColor(bool haveTaskbar, bool horizontal)
    {
        Rectangle bar = haveTaskbar && TryGetTaskbar(out Rectangle taskbar, out _, out _)
            ? taskbar
            : Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 100, 100);

        // Sample immediately left of the strip, inside the taskbar band.
        int x = horizontal ? Math.Max(bar.Left + 2, Left - Scaled(24)) : bar.Left + bar.Width / 2;
        int y = horizontal ? bar.Top + bar.Height / 2 : Math.Max(bar.Top + 2, Top - Scaled(8));

        double luminance = 0;
        int samples = 0;
        for (int offset = 0; offset < 3; offset++)
        {
            int sampleX = Math.Clamp(x - offset * Scaled(6), bar.Left, bar.Right - 1);
            int sampleY = Math.Clamp(y + offset, bar.Top, bar.Bottom - 1);
            try
            {
                using var bitmap = new Bitmap(1, 1);
                using (Graphics graphics = Graphics.FromImage(bitmap))
                {
                    graphics.CopyFromScreen(sampleX, sampleY, 0, 0, new Size(1, 1));
                }
                Color pixel = bitmap.GetPixel(0, 0);
                luminance += 0.2126 * pixel.R + 0.7152 * pixel.G + 0.0722 * pixel.B;
                samples++;
            }
            catch (Exception)
            {
                // Sampling is cosmetic; fall through to the default below.
            }
        }

        if (samples == 0)
        {
            return Color.FromArgb(0xf0, 0xf0, 0xf0);
        }
        return luminance / samples > 150
            ? Color.FromArgb(0x1a, 0x1a, 0x1a)
            : Color.FromArgb(0xf0, 0xf0, 0xf0);
    }

    /// <summary>
    /// Put the strip inside the taskbar band, next to the notification area.
    /// Falls back to just above the taskbar when the taskbar cannot be found.
    /// </summary>
    private void DockToTaskbar()
    {
        if (TryGetTaskbar(out Rectangle taskbar, out int trayLeft, out Rectangle tray))
        {
            bool horizontal = taskbar.Width >= taskbar.Height;
            if (horizontal)
            {
                int x = trayLeft - Width - Scaled(10);
                int y = taskbar.Top + (taskbar.Height - Height) / 2;
                Location = new Point(Math.Max(taskbar.Left + Scaled(4), x), y);
            }
            else
            {
                int x = taskbar.Left + (taskbar.Width - Width) / 2;
                int y = tray.IsEmpty ? taskbar.Bottom - Height - Scaled(4) : tray.Top - Height - Scaled(4);
                Location = new Point(Math.Max(taskbar.Left + Scaled(2), x),
                    Math.Max(taskbar.Top + Scaled(2), y));
            }
        }
        else
        {
            Screen screen = Screen.PrimaryScreen ?? Screen.FromPoint(Cursor.Position);
            Rectangle area = screen.WorkingArea;
            int margin = Scaled(8);
            Location = new Point(area.Right - Width - margin, area.Bottom - Height - margin);
        }
    }

    private static bool TryGetTaskbar(out Rectangle taskbar, out int trayLeft, out Rectangle trayRect)
    {
        taskbar = Rectangle.Empty;
        trayLeft = 0;
        trayRect = Rectangle.Empty;

        IntPtr handle = FindWindow("Shell_TrayWnd", null);
        if (handle == IntPtr.Zero || !IsWindowVisible(handle) || !GetWindowRect(handle, out Rect rect))
        {
            return false;
        }

        taskbar = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        trayLeft = taskbar.Right;

        IntPtr tray = FindWindowEx(handle, IntPtr.Zero, "TrayNotifyWnd", null);
        if (tray != IntPtr.Zero && GetWindowRect(tray, out Rect trayWindow))
        {
            trayRect = Rectangle.FromLTRB(trayWindow.Left, trayWindow.Top, trayWindow.Right,
                trayWindow.Bottom);
            trayLeft = trayRect.Left;
        }
        return true;
    }

    /// <summary>Draw to an ARGB bitmap and blit it with per-pixel alpha.</summary>
    private void RenderLayered()
    {
        if (!IsHandleCreated || Width <= 0 || Height <= 0)
        {
            return;
        }

        using var bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            // A very low alpha keeps the whole strip hit-testable (Windows treats
            // pixels with alpha 0 as click-through) while staying invisible.
            graphics.Clear(Color.FromArgb(12, 0, 0, 0));
            DrawContent(graphics);
        }
        Premultiply(bitmap);

        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memoryDc = CreateCompatibleDC(screenDc);
        IntPtr hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
        IntPtr previous = SelectObject(memoryDc, hBitmap);
        try
        {
            var size = new Size(Width, Height);
            var source = new Point(0, 0);
            var destination = new Point(Left, Top);
            var blend = new BlendFunction
            {
                BlendOp = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = 1,
            };
            UpdateLayeredWindow(Handle, screenDc, ref destination, ref size, memoryDc, ref source, 0,
                ref blend, 2);
        }
        finally
        {
            SelectObject(memoryDc, previous);
            DeleteObject(hBitmap);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private void DrawContent(Graphics graphics)
    {
        int rowWidth = Width - _padding * 2;

        if (_devices.Count == 0)
        {
            string emptyText = _anyHidden ? "已隐藏全部设备" : "未发现鼠标";
            TextRenderer.DrawText(graphics, emptyText, _nameFont,
                new Rectangle(_padding, _padding, rowWidth, _rowHeight), _mutedColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            return;
        }

        int index = 0;
        foreach (DeviceOutcome device in _devices.Take(_rowsShown))
        {
            int top = _padding + index * _rowHeight;
            bool stale = device.Stale || device.Battery is null;
            Color level = stale
                ? _mutedColor
                : BatteryIcon.LevelColor(device.Battery, device.Charging == true);

            int batteryLeft = _padding + rowWidth - _batteryWidth;
            int batteryTop = top + (_rowHeight - _batteryHeight) / 2;
            int bodyWidth = _batteryWidth - _batteryCapGap - _batteryCapWidth;
            var body = new Rectangle(batteryLeft, batteryTop, bodyWidth, _batteryHeight);

            // Outline, translucent fill and cap: the macOS menu bar battery.
            using (var outline = new Pen(Color.FromArgb(217, level), 1.2f))
            using (GraphicsPath path = RoundedRectangle(body, Scaled(3)))
            {
                graphics.DrawPath(outline, path);
            }

            double fraction = Math.Clamp((device.Battery ?? 0) / 100.0, 0, 1);
            int fillWidth = (int)Math.Round((bodyWidth - 3) * fraction);
            if (fillWidth > 1)
            {
                using var brush = new SolidBrush(Color.FromArgb(110, level));
                using GraphicsPath fill = RoundedRectangle(
                    new Rectangle(batteryLeft + 2, batteryTop + 2, fillWidth,
                        Math.Max(1, _batteryHeight - 4)), Scaled(1));
                graphics.FillPath(brush, fill);
            }

            using (var cap = new SolidBrush(Color.FromArgb(217, level)))
            {
                int capHeight = Math.Max(3, _batteryHeight * 2 / 5);
                graphics.FillRectangle(cap, batteryLeft + bodyWidth + _batteryCapGap,
                    batteryTop + (_batteryHeight - capHeight) / 2, _batteryCapWidth, capHeight);
            }

            // The number (and a bolt while charging) sits inside the outline.
            int innerLeft = batteryLeft + _batteryTextPad;
            if (_boltWidth > 0 && device.Charging == true && !stale)
            {
                using var bolt = new SolidBrush(_textColor);
                float x = innerLeft;
                float y = batteryTop + 1;
                float height = _batteryHeight - 2;
                float width = _boltWidth;
                graphics.FillPolygon(bolt, new[]
                {
                    new PointF(x + width * 0.6f, y),
                    new PointF(x, y + height * 0.55f),
                    new PointF(x + width * 0.42f, y + height * 0.55f),
                    new PointF(x + width * 0.2f, y + height),
                    new PointF(x + width, y + height * 0.38f),
                    new PointF(x + width * 0.52f, y + height * 0.38f),
                });
            }
            if (device.Charging == true && !stale)
            {
                innerLeft += _boltWidth;
            }

            TextRenderer.DrawText(graphics, device.BatteryText(), _valueFont,
                new Rectangle(innerLeft, batteryTop, _valueWidth, _batteryHeight), _textColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

            int nameWidth = Math.Max(0, batteryLeft - _gap * 2 - _padding);
            TextRenderer.DrawText(graphics, device.Name, _nameFont,
                new Rectangle(_padding, top, nameWidth, _rowHeight), _textColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            index++;
        }

        if (_overflow > 0)
        {
            int top = _padding + index * _rowHeight;
            TextRenderer.DrawText(graphics, $"+{_overflow} 台", _nameFont,
                new Rectangle(_padding, top, rowWidth, _rowHeight), _mutedColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }

    /// <summary>
    /// `UpdateLayeredWindow` expects premultiplied alpha; GDI+ bitmaps are
    /// straight alpha, so a translucent fill would otherwise blend too bright.
    /// </summary>
    private static void Premultiply(Bitmap bitmap)
    {
        BitmapData data = bitmap.LockBits(
            new Rectangle(0, 0, bitmap.Width, bitmap.Height),
            ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            int length = Math.Abs(data.Stride) * bitmap.Height;
            var pixels = new byte[length];
            Marshal.Copy(data.Scan0, pixels, 0, length);
            for (int index = 0; index + 3 < length; index += 4)
            {
                int alpha = pixels[index + 3];
                if (alpha is 0 or 255)
                {
                    continue;
                }
                pixels[index] = (byte)(pixels[index] * alpha / 255);
                pixels[index + 1] = (byte)(pixels[index + 1] * alpha / 255);
                pixels[index + 2] = (byte)(pixels[index + 2] * alpha / 255);
            }
            Marshal.Copy(pixels, 0, data.Scan0, length);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
    {
        int diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        var path = new GraphicsPath();
        if (diameter <= 0)
        {
            path.AddRectangle(bounds);
            return path;
        }

        var arc = new Rectangle(bounds.Location, new Size(diameter, diameter));
        path.AddArc(arc, 180, 90);
        arc.X = bounds.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = bounds.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = bounds.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // Layered windows are painted through UpdateLayeredWindow only.
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // Nothing: the background is fully transparent.
    }

    protected override void OnLocationChanged(EventArgs e)
    {
        base.OnLocationChanged(e);
        RenderLayered();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Relayout();
        RenderLayered();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button is not (MouseButtons.Left or MouseButtons.Right))
        {
            return;
        }
        _dragging = true;
        _movedSincePress = false;
        _pressPoint = Cursor.Position;
        _pressLocation = Location;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!_dragging)
        {
            return;
        }

        Point cursor = Cursor.Position;
        if (!_movedSincePress &&
            (Math.Abs(cursor.X - _pressPoint.X) > DragThreshold ||
             Math.Abs(cursor.Y - _pressPoint.Y) > DragThreshold))
        {
            _movedSincePress = true;
        }
        if (_movedSincePress)
        {
            Location = new Point(
                _pressLocation.X + cursor.X - _pressPoint.X,
                _pressLocation.Y + cursor.Y - _pressPoint.Y);
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        bool wasDrag = _movedSincePress;
        _dragging = false;
        _movedSincePress = false;
        if (wasDrag)
        {
            _savedPosition = Location;
            Moved?.Invoke(this, Location);
            return;
        }
        if (e.Button is MouseButtons.Left or MouseButtons.Right)
        {
            Clicked?.Invoke(this, EventArgs.Empty);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _watchTimer.Stop();
            _watchTimer.Dispose();
            _nameFont?.Dispose();
            _valueFont?.Dispose();
        }
        base.Dispose(disposing);
    }

    private static bool IsOnScreen(Point point)
    {
        foreach (Screen screen in Screen.AllScreens)
        {
            Rectangle bounds = screen.Bounds;
            if (point.X >= bounds.Left - 8 && point.Y >= bounds.Top - 8 &&
                point.X < bounds.Right - 16 && point.Y < bounds.Bottom - 16)
            {
                return true;
            }
        }
        return false;
    }

    // ---- Win32 ---------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindow(string? className, string? windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? className,
        string? windowName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, char[] name, int length);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y,
        int width, int height, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc,
        ref Point destinationPoint, ref Size size, IntPtr sourceDc, ref Point sourcePoint,
        int colorKey, ref BlendFunction blend, int flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr dc, IntPtr gdiObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr gdiObject);
}
