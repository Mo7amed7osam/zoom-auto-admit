using System.Text;
using ZoomAutoAdmit.Core.Formatting;

namespace ZoomAutoAdmit.WindowsRuntime.Scheduling;

public static class WindowsSchedulerLog
{
    private static readonly object Sync = new();

    public static string FilePath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ZoomAutoAdmit",
        "Logs",
        "scheduler.log");

    public static void Write(string tag, string message)
    {
        try
        {
            string? dir = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            string formattedTag = tag.StartsWith('[') && tag.EndsWith(']') ? tag : $"[{tag}]";
            string line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss}] {formattedTag} {message}{Environment.NewLine}";
            lock (Sync)
            {
                File.AppendAllText(FilePath, line, Encoding.UTF8);
            }
        }
        catch
        {
            // Logging must never crash the caller.
        }

        try
        {
            string formattedTag = tag.StartsWith('[') && tag.EndsWith(']') ? tag : $"[{tag}]";
            if (formattedTag.Equals("[ERROR]", StringComparison.OrdinalIgnoreCase))
            {
                ConsoleLogger.Error($"[SCHEDULER] {message}");
            }
            else
            {
                ConsoleLogger.Info($"[SCHEDULER] {formattedTag} {message}");
            }
        }
        catch
        {
        }
    }
}
