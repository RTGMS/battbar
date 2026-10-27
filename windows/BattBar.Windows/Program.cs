namespace BattBar;

internal static class Program
{
    /// <summary>
    /// Single instance: the mutex lives for the process, so launching again
    /// exits immediately instead of adding a second tray icon.
    /// </summary>
    private const string MutexName = @"Local\BattBarTray";

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, MutexName, out bool created);
        if (!created)
        {
            return;
        }

        ApplicationConfiguration.Initialize();

        Settings settings = Settings.Load();
        if (Autostart.Enabled != settings.StartWithWindows)
        {
            // The registry is the source of truth for the checkbox.
            settings.StartWithWindows = Autostart.Enabled;
        }

        Application.Run(new TrayApplication(settings));
    }
}
