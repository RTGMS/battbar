using System.Reflection;
using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// The tray icon and its menu.
///
/// Owns the scan timer and the notification-area icon; every decision comes from
/// the core (see <see cref="CoreDecisions"/>).
/// </summary>
internal sealed class TrayApplication : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly BatteryStrip _strip;
    private readonly ShellRestartWatcher _shell;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly System.Windows.Forms.Timer _retryTimer;
    private readonly Settings _settings;
    private readonly IntPtr _alerts;

    private List<DeviceOutcome> _devices = new();
    /// <summary>Devices the user did not hide (drives the icon, strip and alerts).</summary>
    private List<DeviceOutcome> _visible = new();
    private List<string> _issues = new();
    private int _activeIndex;
    private ContextMenuStrip? _menu;
    private bool _scanning;
    private bool _retrying;

    internal TrayApplication(Settings settings)
    {
        _settings = settings;
        _alerts = Core.battbar_alerts_new();

        _tray = new NotifyIcon
        {
            Visible = true,
            Text = "电量栏",
            Icon = AppIcon,
        };
        _tray.MouseClick += OnTrayClick;

        // Always-visible readings: the notification area only shows an icon, so
        // the numbers live in this strip next to it.
        _strip = new BatteryStrip { SavedPosition = _settings.StripPosition };
        _strip.Clicked += (_, _) => ShowMenu();
        _strip.Moved += (_, point) =>
        {
            _settings.SetStripPosition(point);
            Persist();
        };

        // Explorer sends TaskbarCreated after it restarts; the tray icon and the
        // strip both have to be re-added to the new notification area.
        _shell = new ShellRestartWatcher();
        _shell.ExplorerRestarted += (_, _) =>
        {
            _tray.Visible = true;
            UpdateStrip();
        };

        _timer = new System.Windows.Forms.Timer { Interval = _settings.RefreshInterval * 1000 };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();

        _retryTimer = new System.Windows.Forms.Timer();
        _retryTimer.Tick += (_, _) =>
        {
            _retryTimer.Stop();
            _retrying = true;
            Refresh();
        };

        // The first scan cannot start here: TaskScheduler's
        // FromCurrentSynchronizationContext() needs the WinForms context, which
        // only exists once Application.Run is pumping messages. Idle fires then.
        Application.Idle += OnFirstIdle;
    }

    /// <summary>Runs the first scan as soon as the message loop is idle.</summary>
    private void OnFirstIdle(object? sender, EventArgs e)
    {
        Application.Idle -= OnFirstIdle;
        Refresh();
    }

    private void OnTrayClick(object? sender, MouseEventArgs args)
    {
        if (args.Button is MouseButtons.Left or MouseButtons.Right)
        {
            ShowMenu();
        }
    }

    /// <summary>Scan on a worker thread so the UI never blocks on a sleeping mouse.</summary>
    private void Refresh()
    {
        // Any scan supersedes a pending retry: it is the same attempt sooner.
        _retryTimer.Stop();
        if (_scanning)
        {
            // This attempt never ran, so hand the retry budget back instead of
            // letting the scan in flight consume it.
            _retrying = false;
            return;
        }
        _scanning = true;

        List<DeviceOutcome> previous = _devices;
        Task.Run(() =>
        {
            ScanResult scan = Providers.ScanAll();
            return (Merged: CoreDecisions.Merge(scan.Devices, previous, scan.Failed,
                _settings.SelectedDeviceId), scan.Issues);
        }).ContinueWith(task =>
        {
            _scanning = false;
            if (task.IsFaulted)
            {
                _tray.Text = "电量栏 · 读取失败";
                ScheduleRetry();
                return;
            }

            (List<DeviceOutcome> devices, int active) merged = task.Result.Merged;
            _devices = merged.devices;
            _issues = task.Result.Issues;
            _activeIndex = _devices.Count == 0 ? -1 : Math.Clamp(merged.active, 0, _devices.Count - 1);
            _visible = VisibleDevices();
            ApplyIcon();
            UpdateStrip();
            Notify();
            ScheduleRetry();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>
    /// One extra scan after a dropped read. The budget and the delay come from
    /// the core; this only owns the WinForms timer.
    /// </summary>
    private void ScheduleRetry()
    {
        _retryTimer.Stop();
        int? delay = CoreDecisions.RetryDelayMilliseconds(
            _visible.Any(device => device.Stale),
            _retrying);
        _retrying = false;
        if (delay is not int milliseconds)
        {
            return;
        }
        _retryTimer.Interval = milliseconds;
        _retryTimer.Start();
    }

    private void ApplyIcon() => _tray.Text = Truncate(Tooltip(), 63);

    /// <summary>The application icon, embedded from build/icon.ico.</summary>
    private static readonly Icon AppIcon = LoadAppIcon();

    private static Icon LoadAppIcon()
    {
        try
        {
            using Stream? stream = typeof(TrayApplication).Assembly
                .GetManifestResourceStream("BattBar.ico");
            if (stream is not null)
            {
                return new Icon(stream);
            }
        }
        catch (Exception)
        {
            // A missing icon must not stop the app.
        }
        return SystemIcons.Application;
    }

    /// <summary>Devices that are not hidden in the menu's “显示设备” list.</summary>
    private List<DeviceOutcome> VisibleDevices() =>
        _devices.Where(device => !_settings.IsHidden(device.Id)).ToList();

    /// <summary>
    /// Tooltip: the readings, worded like the macOS status item. Provider issues
    /// are not surfaced here — macOS shows them in the panel only, and a balloon
    /// for a sleeping mouse is noise.
    /// </summary>
    private string Tooltip() => BatteryIcon.Tooltip(_visible);

    /// <summary>Refresh the always-visible strip (or hide it when turned off).</summary>
    private void UpdateStrip()
    {
        if (!_settings.ShowFloatingStrip)
        {
            _strip.HideStrip();
            return;
        }
        _strip.UpdateContent(_visible, _devices.Count > 0);
    }

    private void Notify()
    {
        foreach ((int kind, string deviceId, byte battery) in
                 CoreDecisions.Evaluate(_alerts, _visible, _settings.LowBatteryAlerts))
        {
            DeviceOutcome? device = _visible.FirstOrDefault(candidate => candidate.Id == deviceId);
            if (device is null)
            {
                continue;
            }

            (string title, string body) = kind switch
            {
                2 => ($"鼠标电量仅剩 {battery}%", $"{device.Name} 快没电了，建议立即充电。"),
                _ => ($"鼠标电量偏低（{battery}%）", $"{device.Name} 建议尽快充电，避免使用中断。"),
            };
            _tray.ShowBalloonTip(5000, title, body, ToolTipIcon.Info);
        }
    }

    /// <summary>
    /// Show the tray menu at the cursor.
    ///
    /// The menu is shown through NotifyIcon's own (private) <c>ShowContextMenu</c>:
    /// that is the path WinForms uses for a real right-click, and it calls
    /// <c>SetForegroundWindow</c> on the tray icon's message window first. Without
    /// that step a <see cref="ContextMenuStrip"/> shown from a no-activate window
    /// never closes when the user clicks somewhere else.
    /// </summary>
    private void ShowMenu()
    {
        // A ContextMenuStrip is a Component: the previous one must be disposed,
        // otherwise every right-click leaks a menu with its GDI handles.
        _menu?.Dispose();
        ContextMenuStrip menu = BuildMenu();
        _menu = menu;
        _tray.ContextMenuStrip = menu;
        menu.Closed += (_, _) =>
        {
            if (ReferenceEquals(_tray.ContextMenuStrip, menu))
            {
                _tray.ContextMenuStrip = null;
            }
        };

        try
        {
            ShowTrayMenuMethod?.Invoke(_tray, null);
        }
        catch (Exception)
        {
            // Reflection is best effort: the plain Show below still works, it
            // just may not dismiss on an outside click on some builds.
            menu.Show(Cursor.Position);
        }
    }

    private static readonly MethodInfo? ShowTrayMenuMethod = typeof(NotifyIcon).GetMethod(
        "ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        if (_devices.Count == 0)
        {
            menu.Items.Add(new ToolStripMenuItem("未发现鼠标") { Enabled = false });
        }
        else
        {
            for (int index = 0; index < _devices.Count; index++)
            {
                DeviceOutcome device = _devices[index];
                bool hidden = _settings.IsHidden(device.Id);
                string label = hidden
                    ? $"{device.Name}：{device.BatteryText()}（已隐藏）"
                    : $"{device.Name}：{device.BatteryText()}";
                var item = new ToolStripMenuItem(label)
                {
                    Checked = !hidden && index == _activeIndex,
                };
                int captured = index;
                item.Click += (_, _) =>
                {
                    _activeIndex = captured;
                    _settings.SelectedDeviceId = device.Id;
                    Persist();
                    ApplyIcon();
                };
                menu.Items.Add(item);
            }
        }

        // Per-device visibility. A wired mouse still answers the protocol, but
        // its level is noise next to the wireless one, so it can be hidden
        // without touching the protocol layer (there is no reliable
        // wired/wireless bit in either vendor protocol).
        if (_devices.Count > 0)
        {
            var visibility = new ToolStripMenuItem("显示设备");
            foreach (DeviceOutcome device in _devices)
            {
                var item = new ToolStripMenuItem(device.Name)
                {
                    Checked = !_settings.IsHidden(device.Id),
                };
                string id = device.Id;
                item.Click += (_, _) =>
                {
                    _settings.SetHidden(id, !_settings.IsHidden(id));
                    Persist();
                    _visible = VisibleDevices();
                    ApplyIcon();
                    UpdateStrip();
                };
                visibility.DropDownItems.Add(item);
            }
            menu.Items.Add(visibility);
        }

        var stripMenu = new ToolStripMenuItem("常驻电量条");
        var stripVisible = new ToolStripMenuItem("显示任务栏电量")
        {
            Checked = _settings.ShowFloatingStrip,
        };
        stripVisible.Click += (_, _) =>
        {
            _settings.ShowFloatingStrip = !_settings.ShowFloatingStrip;
            Persist();
            UpdateStrip();
        };
        stripMenu.DropDownItems.Add(stripVisible);
        stripMenu.DropDownItems.Add(new ToolStripMenuItem("归位到通知区域左侧", null, (_, _) =>
        {
            _settings.ClearStripPosition();
            Persist();
            _strip.ResetPosition();
        }));
        menu.Items.Add(stripMenu);

        if (_issues.Count > 0)
        {
            menu.Items.Add(new ToolStripMenuItem($"提示：{Truncate(_issues[0], 80)}") { Enabled = false });
        }

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("刷新电量", null, (_, _) => Refresh()));

        var alertsItem = new ToolStripMenuItem("低电量提醒")
        {
            Checked = _settings.LowBatteryAlerts,
        };
        alertsItem.Click += (_, _) =>
        {
            _settings.LowBatteryAlerts = !_settings.LowBatteryAlerts;
            Persist();
        };
        menu.Items.Add(alertsItem);

        var autostartItem = new ToolStripMenuItem("开机自动启动")
        {
            Checked = _settings.StartWithWindows,
        };
        autostartItem.Click += (_, _) =>
        {
            if (!Autostart.Set(!_settings.StartWithWindows))
            {
                Balloon("无法修改开机启动项（注册表拒绝写入）。", ToolTipIcon.Warning);
            }
            // The registry is the source of truth, not the click.
            _settings.StartWithWindows = Autostart.Enabled;
            autostartItem.Checked = _settings.StartWithWindows;
            Persist();
        };
        menu.Items.Add(autostartItem);

        var intervalMenu = new ToolStripMenuItem("自动刷新");
        foreach (int interval in Settings.RefreshOptions)
        {
            string label = interval switch
            {
                30 => "每 30 秒",
                300 => "每 5 分钟",
                _ => $"每 {interval} 秒",
            };
            var item = new ToolStripMenuItem(label)
            {
                Checked = _settings.RefreshInterval == interval,
            };
            int captured = interval;
            item.Click += (_, _) =>
            {
                _settings.RefreshInterval = captured;
                Persist();
                _timer.Interval = captured * 1000;
            };
            intervalMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(intervalMenu);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("退出电量栏", null, (_, _) => ExitThread()));

        return menu;
    }

    /// <summary>Save and say so when the file could not be written.</summary>
    private void Persist()
    {
        if (!_settings.Save())
        {
            Balloon($"设置无法保存：{Settings.Path}", ToolTipIcon.Warning);
        }
    }

    private void Balloon(string text, ToolTipIcon icon) =>
        _tray.ShowBalloonTip(5000, "电量栏", text, icon);

    private static string Truncate(string text, int limit) =>
        text.Length <= limit ? text : text[..limit];

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Stop();
            _timer.Dispose();
            _retryTimer.Stop();
            _retryTimer.Dispose();
            _menu?.Dispose();
            _shell.Dispose();
            _strip.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            if (_alerts != IntPtr.Zero)
            {
                Core.battbar_alerts_free(_alerts);
            }
        }
        base.Dispose(disposing);
    }
}
