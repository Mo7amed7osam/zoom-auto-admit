using System.IO;
using System.Text;

namespace ZoomAutoAdmit.WindowsUI.Infrastructure;

public static class WindowsUiErrorLog
{
    private static readonly object Sync = new();

    public static string FilePath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ZoomAutoAdmit",
        "Logs",
        "windows-ui.log");

    public static void Write(string context, Exception exception)
    {
        try
        {
            string directory = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(directory);
            string entry = $"[{DateTimeOffset.Now:O}] {context}{Environment.NewLine}{exception}{Environment.NewLine}{Environment.NewLine}";
            lock (Sync) File.AppendAllText(FilePath, entry, Encoding.UTF8);
        }
        catch
        {
            // Error reporting must not create another application failure.
        }
    }
}
