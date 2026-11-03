using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// Listens for Explorer's <c>TaskbarCreated</c> broadcast, which Windows sends
/// after the shell restarts. The notification area is rebuilt from scratch at
/// that point, so the tray icon and the strip have to be re-added — otherwise
/// the app looks dead after "重启资源管理器".
/// </summary>
internal sealed class ShellRestartWatcher : NativeWindow, IDisposable
{
    private static readonly int TaskbarCreated = RegisterWindowMessage("TaskbarCreated");

    internal ShellRestartWatcher()
    {
        CreateHandle(new CreateParams { Caption = "BattBarShellWatcher" });
    }

    internal event EventHandler? ExplorerRestarted;

    protected override void WndProc(ref Message message)
    {
        if (TaskbarCreated != 0 && message.Msg == TaskbarCreated)
        {
            ExplorerRestarted?.Invoke(this, EventArgs.Empty);
        }
        base.WndProc(ref message);
    }

    public void Dispose() => DestroyHandle();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterWindowMessage(string message);
}
