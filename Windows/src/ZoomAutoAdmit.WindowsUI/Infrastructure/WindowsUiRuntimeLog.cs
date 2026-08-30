using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Data;

namespace ZoomAutoAdmit.WindowsUI.Infrastructure;

public static class WindowsUiRuntimeLog
{
    private static readonly object Sync = new();
    private static readonly TraceListener BindingListener = new BindingTraceListener();
    private static bool _initialized;

    public static string FilePath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ZoomAutoAdmit",
        "Logs",
        "ui-runtime.log");

    public static void Initialize()
    {
        lock (Sync)
        {
            if (_initialized) return;
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Warning | SourceLevels.Error;
            PresentationTraceSources.DataBindingSource.Listeners.Add(BindingListener);
            _initialized = true;
        }
        Write("STARTUP", "Diagnostics initialized.");
    }

    public static void Write(string category, string message)
    {
        try
        {
            string line = $"[{DateTimeOffset.Now:O}] [{category}] {message}{Environment.NewLine}";
            lock (Sync) File.AppendAllText(FilePath, line, Encoding.UTF8);
        }
        catch
        {
            // Diagnostics must never affect application lifetime.
        }
    }

    public static void Shutdown()
    {
        lock (Sync)
        {
            if (!_initialized) return;
            PresentationTraceSources.DataBindingSource.Listeners.Remove(BindingListener);
            _initialized = false;
        }
        Write("SHUTDOWN", "Diagnostics stopped.");
    }

    private sealed class BindingTraceListener : TraceListener
    {
        public override void Write(string? message)
        {
            if (!string.IsNullOrWhiteSpace(message)) WindowsUiRuntimeLog.Write("BINDING", message);
        }

        public override void WriteLine(string? message) => Write(message);
    }
}
