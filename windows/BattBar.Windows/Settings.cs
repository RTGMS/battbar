using System.Text.Json;
using System.Text.Json.Serialization;

namespace BattBar;

/// <summary>User settings, stored next to the app data.</summary>
internal sealed class Settings
{
    /// <summary>Refresh intervals offered in the menu, in seconds.</summary>
    internal static readonly int[] RefreshOptions = { 30, 60, 300 };

    [JsonPropertyName("refresh_interval")]
    public int RefreshInterval { get; set; } = 60;

    [JsonPropertyName("low_battery_alerts")]
    public bool LowBatteryAlerts { get; set; } = true;

    [JsonPropertyName("start_with_windows")]
    public bool StartWithWindows { get; set; }

    [JsonPropertyName("selected_device_id")]
    public string? SelectedDeviceId { get; set; }

    /// <summary>Show the always-on-top battery strip next to the tray.</summary>
    [JsonPropertyName("show_floating_strip")]
    public bool ShowFloatingStrip { get; set; } = true;

    /// <summary>Devices the user asked not to show (e.g. a wired mouse).</summary>
    [JsonPropertyName("hidden_device_ids")]
    public List<string> HiddenDeviceIds { get; set; } = new();

    /// <summary>Where the user dragged the strip, if anywhere.</summary>
    [JsonPropertyName("strip_x")]
    public int? StripX { get; set; }

    [JsonPropertyName("strip_y")]
    public int? StripY { get; set; }

    [JsonIgnore]
    internal Point? StripPosition =>
        StripX is { } x && StripY is { } y ? new Point(x, y) : null;

    internal void SetStripPosition(Point point)
    {
        StripX = point.X;
        StripY = point.Y;
    }

    internal void ClearStripPosition()
    {
        StripX = null;
        StripY = null;
    }

    [JsonIgnore]
    internal static string Path => System.IO.Path.Combine(DataDirectory, "settings.json");

    internal bool IsHidden(string deviceId) => HiddenDeviceIds.Contains(deviceId);

    /// <summary>Show or hide one device in the tray and the strip.</summary>
    internal void SetHidden(string deviceId, bool hidden)
    {
        if (string.IsNullOrEmpty(deviceId))
        {
            return;
        }
        bool present = HiddenDeviceIds.Contains(deviceId);
        if (hidden && !present)
        {
            HiddenDeviceIds.Add(deviceId);
        }
        else if (!hidden && present)
        {
            HiddenDeviceIds.RemoveAll(candidate => candidate == deviceId);
        }
    }

    [JsonIgnore]
    internal static string DataDirectory =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "BattBar");

    internal static Settings Load()
    {
        try
        {
            if (File.Exists(Path))
            {
                Settings? loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path));
                if (loaded is not null)
                {
                    loaded.Sanitize();
                    return loaded;
                }
            }
        }
        catch (Exception)
        {
            // A broken file must not stop the app; fall back to defaults.
        }
        return new Settings();
    }

    /// <summary>Persist the settings; false when the file could not be written.</summary>
    internal bool Save()
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            File.WriteAllText(Path,
                JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            return true;
        }
        catch (Exception)
        {
            // The caller decides how to tell the user; swallowing silently made
            // the menu and the disk disagree with no explanation.
            return false;
        }
    }

    internal void Sanitize()
    {
        if (!RefreshOptions.Contains(RefreshInterval))
        {
            RefreshInterval = 60;
        }
        if (SelectedDeviceId is { Length: 0 or > 512 })
        {
            SelectedDeviceId = null;
        }
        // Keep a bounded, sane list: ids come from settings files users can edit.
        HiddenDeviceIds = HiddenDeviceIds
            .Where(id => !string.IsNullOrWhiteSpace(id) && id.Length <= 512)
            .Distinct(StringComparer.Ordinal)
            .Take(32)
            .ToList();
    }
}
