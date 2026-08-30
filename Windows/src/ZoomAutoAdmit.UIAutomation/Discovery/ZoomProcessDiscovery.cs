using System.Diagnostics;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Discovery;

public class ZoomProcessDiscovery
{
    private static readonly string[] KnownZoomProcessNames =
    {
        "Zoom",
        "CptHost",
        "airhost",
        "ZoomRooms",
        "zCtrlUI"
    };

    public IReadOnlyList<ZoomProcessCandidate> FindCandidates(bool logInfo = true)
    {
        if (logInfo) ConsoleLogger.Info("Scanning system for Zoom Workplace processes...");
        var candidates = new List<ZoomProcessCandidate>();
        var allProcesses = Process.GetProcesses();

        foreach (var process in allProcesses)
        {
            try
            {
                var name = process.ProcessName;
                if (name.StartsWith("ZoomAutoAdmit", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var isMatch = KnownZoomProcessNames.Any(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase))
                              || name.IndexOf("zoom", StringComparison.OrdinalIgnoreCase) >= 0;

                if (!isMatch)
                {
                    continue;
                }

                var path = ProcessHelper.TryGetMainModuleFileName(process);
                var mainWindowHandle = IntPtr.Zero;
                var mainWindowTitle = string.Empty;

                try
                {
                    mainWindowHandle = process.MainWindowHandle;
                    mainWindowTitle = process.MainWindowTitle;
                }
                catch
                {
                    // Access / querying limitation on some handles
                }

                var windows = ProcessHelper.GetWindowsForProcess(process.Id);
                var isAccessible = windows.Count > 0 || mainWindowHandle != IntPtr.Zero;

                candidates.Add(new ZoomProcessCandidate(
                    process.Id,
                    name,
                    path,
                    mainWindowHandle,
                    mainWindowTitle,
                    windows,
                    isAccessible
                ));
            }
            catch (Exception ex)
            {
                ConsoleLogger.Debug($"Skipping process {process.Id} due to access error: {ex.Message}");
            }
        }

        // Sort candidates: prioritize processes named 'Zoom' with visible windows
        var ordered = candidates
            .OrderByDescending(c => c.ProcessName.Equals("Zoom", StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(c => c.Windows.Count(w => w.IsVisible))
            .ThenBy(c => c.ProcessId)
            .ToList();

        if (logInfo) ConsoleLogger.Info($"Process scan complete. Found {ordered.Count} candidate process(es).");
        return ordered;
    }

    public ZoomProcessCandidate? FindPrimaryCandidate(int? targetProcessId = null)
    {
        var candidates = FindCandidates();

        if (targetProcessId.HasValue)
        {
            var match = candidates.FirstOrDefault(c => c.ProcessId == targetProcessId.Value);
            if (match == null)
            {
                ConsoleLogger.Warn($"Specified process PID {targetProcessId.Value} was not found among Zoom candidates.");
            }
            return match;
        }

        // Return first viable Zoom process
        return candidates.FirstOrDefault(c => c.ProcessName.Equals("Zoom", StringComparison.OrdinalIgnoreCase))
               ?? candidates.FirstOrDefault();
    }
}
