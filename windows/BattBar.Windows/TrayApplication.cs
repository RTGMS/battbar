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
    private readonly System.Windows.Forms.Timer _timer;
    private readonly System.Windows.Forms.Timer _retryTimer;
    private readonly Settings _settings;
    private readonly IntPtr _alerts;

    private List<DeviceOutcome> _devices = new();
    private int _activeIndex;
    private Icon? _icon;
    private IntPtr _iconHandle;
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
            Icon = SystemIcons.Application,
        };
        _tray.MouseClick += OnTrayClick;

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
            return;
        }
        _scanning = true;

        List<DeviceOutcome> previous = _devices;
        Task.Run(() =>
        {
            ScanResult scan = Providers.ScanAll();
            return CoreDecisions.Merge(scan.Devices, previous, scan.Failed, _settings.SelectedDeviceId);
        }).ContinueWith(task =>
        {
            _scanning = false;
            if (task.IsFaulted)
            {
                _tray.Text = "电量栏 · 读取失败";
                ScheduleRetry();
                return;
            }

            (List<DeviceOutcome> devices, int active) = task.Result;
            _devices = devices;
            _activeIndex = devices.Count == 0 ? -1 : Math.Clamp(active, 0, devices.Count - 1);
            ApplyIcon();
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
            _devices.Any(device => device.Stale),
            _retrying);
        _retrying = false;
        if (delay is not int milliseconds)
        {
            return;
        }
        _retryTimer.Interval = milliseconds;
        _retryTimer.Start();
    }

    private void ApplyIcon()
    {
        DeviceOutcome? active = _activeIndex >= 0 && _activeIndex < _devices.Count
            ? _devices[_activeIndex]
            : _devices.FirstOrDefault();

        (Icon icon, IntPtr handle) = BatteryIcon.Build(active?.Battery, active?.Charging == true);
        _tray.Icon = icon;
        _tray.Text = Truncate(BatteryIcon.Tooltip(_devices), 63);

        // Release the previous icon handle only after the tray stops using it.
        Icon? previousIcon = _icon;
        IntPtr previousHandle = _iconHandle;
        _icon = icon;
        _iconHandle = handle;
        previousIcon?.Dispose();
        BatteryIcon.Release(previousHandle);
    }

    private void Notify()
    {
        foreach ((int kind, string deviceId, byte battery) in
                 CoreDecisions.Evaluate(_alerts, _devices, _settings.LowBatteryAlerts))
        {
            DeviceOutcome? device = _devices.FirstOrDefault(candidate => candidate.Id == deviceId);
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

    private void ShowMenu()
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
                var item = new ToolStripMenuItem($"{device.Name}：{device.BatteryText()}")
                {
                    Checked = index == _activeIndex,
                };
                int captured = index;
                item.Click += (_, _) =>
                {
                    _activeIndex = captured;
                    _settings.SelectedDeviceId = device.Id;
                    _settings.Save();
                    ApplyIcon();
                };
                menu.Items.Add(item);
            }
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
            _settings.Save();
        };
        menu.Items.Add(alertsItem);

        var autostartItem = new ToolStripMenuItem("开机自动启动")
        {
            Checked = _settings.StartWithWindows,
        };
        autostartItem.Click += (_, _) =>
        {
            _settings.StartWithWindows = !_settings.StartWithWindows;
            Autostart.Set(_settings.StartWithWindows);
            _settings.Save();
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
                _settings.Save();
                _timer.Interval = captured * 1000;
            };
            intervalMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(intervalMenu);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("退出电量栏", null, (_, _) => ExitThread()));

        // Show the menu at the cursor, as a notification-area icon should.
        menu.Show(Cursor.Position);
    }

    private static string Truncate(string text, int limit) =>
        text.Length <= limit ? text : text[..limit];

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Stop();
            _timer.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            _icon?.Dispose();
            BatteryIcon.Release(_iconHandle);
            if (_alerts != IntPtr.Zero)
            {
                Core.battbar_alerts_free(_alerts);
            }
        }
        base.Dispose(disposing);
    }
}
