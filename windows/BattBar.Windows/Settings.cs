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

    [JsonIgnore]
    internal static string Path => System.IO.Path.Combine(DataDirectory, "settings.json");

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

    internal void Save()
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            File.WriteAllText(Path,
                JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception)
        {
            // Saving is best effort.
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
    }
}
