using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class MeetingWatchCommand
{
    public static int Execute(CliOptions options)
    {
        var timeoutSeconds = options.TimeoutSeconds;
        // Default to 60s for meeting watch if default was 20
        if (timeoutSeconds == 20 && !options.TimeoutExplicitlySet)
        {
            timeoutSeconds = 60;
        }

        ConsoleLogger.Info("Starting Zoom Meeting & Waiting Room Discovery Watcher...");
        ConsoleLogger.Info($"Options: Timeout={timeoutSeconds}s, MaxDepth={options.MaxDepth}, MaxElements={options.MaxElements}, PID={options.TargetProcessId?.ToString() ?? "auto"}");

        var watcher = new MeetingWatcher();
        var result = watcher.Watch(
            timeoutSeconds,
            options.TargetProcessId,
            options.MaxDepth,
            options.MaxElements
        );

        foreach (var msg in result.Diagnostics)
        {
            ConsoleLogger.Info($"[Diag] {msg}");
        }

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("          ZOOM MEETING & WAITING ROOM DIAGNOSTIC REPORT                         ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        // 1. Detected processes
        Console.WriteLine($"1. Detected Zoom Processes ({result.DetectedProcesses.Count}):");
        foreach (var p in result.DetectedProcesses)
        {
            Console.WriteLine($"   - PID: {p.ProcessId,-6} | Name: {p.ProcessName,-15} | Windows: {p.Windows.Count} | Path: {p.ExecutablePath ?? "(unknown)"}");
        }
        Console.WriteLine();

        // 2. All discovered Zoom windows
        Console.WriteLine($"2. Discovered Zoom Top-Level Windows ({result.AllZoomWindows.Count}):");
        foreach (var w in result.AllZoomWindows)
        {
            Console.WriteLine($"   - HWND: 0x{w.Handle.ToInt64():X8} | PID: {w.ProcessId,-6} | Visible: {w.IsVisible,-5} | Class: '{w.ClassName}' | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }
        Console.WriteLine();

        // 3. Foreground vs Background comparison (State A vs State B)
        Console.WriteLine("================================================================================");
        Console.WriteLine("3. BACKGROUND AUTO-ADMIT VIABILITY COMPARISON (State A vs State B)");
        Console.WriteLine("================================================================================");

        Console.WriteLine($"   State A (Zoom in Foreground) Snapshots: {result.ForegroundSnapshots.Count}");
        var latestFg = result.ForegroundSnapshots.LastOrDefault();
        if (latestFg != null)
        {
            Console.WriteLine($"     - Foreground: '{latestFg.ForegroundWindow.ProcessName}' (HWND: 0x{latestFg.ForegroundWindow.Handle.ToInt64():X8})");
            Console.WriteLine($"     - Waiting Room Rows: {latestFg.WaitingParticipants.Count}");
            Console.WriteLine($"     - Admit Buttons: {latestFg.AdmitButtons.Count}");
            Console.WriteLine($"     - Admit All Buttons: {latestFg.AdmitAllButtons.Count}");
            foreach (var wp in latestFg.WaitingParticipants)
            {
                Console.WriteLine($"       * Participant: '{wp.DisplayName}' | Has Admit Button: {wp.AssociatedAdmitButton != null}");
            }
            foreach (var ab in latestFg.AdmitButtons)
            {
                var patterns = string.Join(", ", ab.Patterns.GetSupportedPatternNames());
                Console.WriteLine($"       * Admit Control: '{ab.Name}' [{ab.ControlType}] | Enabled: {ab.IsEnabled} | Offscreen: {ab.IsOffscreen} | Patterns: [{patterns}]");
            }
        }
        else
        {
            Console.WriteLine("     (No snapshots taken while Zoom was foreground)");
        }
        Console.WriteLine();

        Console.WriteLine($"   State B (Background: Chrome/VSCode in Foreground) Snapshots: {result.BackgroundSnapshots.Count}");
        var latestBg = result.BackgroundSnapshots.LastOrDefault();
        if (latestBg != null)
        {
            Console.WriteLine($"     - Foreground App: '{latestBg.ForegroundWindow.ProcessName}' (Title: '{latestBg.ForegroundWindow.WindowTitle}')");
            Console.WriteLine($"     - Waiting Room Rows: {latestBg.WaitingParticipants.Count}");
            Console.WriteLine($"     - Admit Buttons: {latestBg.AdmitButtons.Count}");
            Console.WriteLine($"     - Admit All Buttons: {latestBg.AdmitAllButtons.Count}");
            foreach (var wp in latestBg.WaitingParticipants)
            {
                Console.WriteLine($"       * Participant: '{wp.DisplayName}' | Has Admit Button: {wp.AssociatedAdmitButton != null}");
            }
            foreach (var ab in latestBg.AdmitButtons)
            {
                var patterns = string.Join(", ", ab.Patterns.GetSupportedPatternNames());
                Console.WriteLine($"       * Admit Control: '{ab.Name}' [{ab.ControlType}] | Enabled: {ab.IsEnabled} | Offscreen: {ab.IsOffscreen} | Patterns: [{patterns}]");
            }

            // Viability verdict
            bool bgReadable = latestBg.WaitingParticipants.Count > 0 || latestBg.AdmitButtons.Count > 0;
            Console.WriteLine();
            Console.WriteLine($"   >>> BACKGROUND VIABILITY VERDICT: {(bgReadable ? "CONFIRMED VIABLE (Elements readable in background)" : "NEEDS VERIFICATION (Check full tree below)")}");
        }
        else
        {
            Console.WriteLine("     (No snapshots taken while Zoom was in background — switch to Chrome/VSCode during watch to test)");
        }
        Console.WriteLine();

        // 4. Captured UI Automation trees
        var allSnapshots = result.ForegroundSnapshots.Concat(result.BackgroundSnapshots).OrderBy(s => s.Timestamp).ToList();
        var sampleSnapshot = result.BackgroundSnapshots.LastOrDefault() ?? result.ForegroundSnapshots.LastOrDefault();

        if (sampleSnapshot != null && sampleSnapshot.MeetingTrees.Count > 0)
        {
            Console.WriteLine("================================================================================");
            Console.WriteLine($"4. CAPTURED UI AUTOMATION TREE(S) ({sampleSnapshot.MeetingTrees.Count} window roots):");
            Console.WriteLine("================================================================================");

            for (int i = 0; i < sampleSnapshot.MeetingTrees.Count; i++)
            {
                var tree = sampleSnapshot.MeetingTrees[i];
                Console.WriteLine($"--- Window Tree #{i + 1} [{tree.ControlType}: '{tree.Name}' (HWND: 0x{tree.NativeWindowHandle.ToInt64():X8}, Class: '{tree.ClassName}')] ---");
                PrintElementRecursive(tree, 0);
                Console.WriteLine();
            }
        }
        else
        {
            Console.WriteLine("4. Captured UI Automation Tree(s): None captured");
        }

        // 5. Events summary
        Console.WriteLine("================================================================================");
        Console.WriteLine($"5. Captured WinEvents ({result.Events.Count} total):");
        Console.WriteLine("================================================================================");
        if (result.Events.Count > 0)
        {
            var grouped = result.Events.GroupBy(e => e.EventName).OrderByDescending(g => g.Count());
            foreach (var g in grouped)
            {
                Console.WriteLine($"   - {g.Key,-30}: {g.Count()} event(s)");
            }
            Console.WriteLine();
            Console.WriteLine("   Sample Chronological Events (up to 50):");
            foreach (var evt in result.Events.Take(50))
            {
                var boundsStr = evt.Bounds != null ? $"{evt.Bounds.X},{evt.Bounds.Y} {evt.Bounds.Width}x{evt.Bounds.Height}" : "n/a";
                Console.WriteLine($"     [{evt.Timestamp:HH:mm:ss.fff}] {evt.EventName,-26} HWND=0x{evt.Hwnd.ToInt64():X8} PID={evt.ProcessId,-6} Class='{evt.WindowClassName}' Title='{evt.WindowTitle}' Bounds=({boundsStr})");
            }
        }

        Console.WriteLine("================================================================================");
        return 0;
    }

    private static void PrintElementRecursive(InspectElementInfo element, int depth)
    {
        var text = ElementFormatter.FormatSingleElement(element, depth * 2);
        Console.Write(text);
        Console.WriteLine();

        foreach (var child in element.Children)
        {
            PrintElementRecursive(child, depth + 1);
        }
    }
}
