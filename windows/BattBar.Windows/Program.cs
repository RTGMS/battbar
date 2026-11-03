namespace BattBar;

internal static class Program
{
    /// <summary>
    /// Single instance: the mutex lives for the process, so launching again
    /// exits immediately instead of adding a second tray icon.
    /// </summary>
    private const string MutexName = @"Local\BattBarTray";

    [STAThread]
    private static int Main(string[] args)
    {
        // Diagnostics first: --probe must work while an instance is running.
        if (args.Any(argument =>
                string.Equals(argument, "--probe", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(argument, "/probe", StringComparison.OrdinalIgnoreCase)))
        {
            return Probe.Run();
        }

        using var mutex = new Mutex(initiallyOwned: true, MutexName, out bool created);
        if (!created)
        {
            return 0;
        }

        ApplicationConfiguration.Initialize();

        Settings settings = Settings.Load();
        if (Autostart.Enabled != settings.StartWithWindows)
        {
            // The registry is the source of truth for the checkbox.
            settings.StartWithWindows = Autostart.Enabled;
        }

        Application.Run(new TrayApplication(settings));
        return 0;
    }
}
