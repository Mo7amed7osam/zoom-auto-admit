using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class ProfileMenuWatchCommand
{
    public static int Execute(CliOptions options)
    {
        var timeoutSeconds = options.TimeoutSeconds;

        ConsoleLogger.Info("Starting Profile Menu WinEvent Watcher...");
        ConsoleLogger.Info($"Options: Timeout={timeoutSeconds}s, MaxDepth={options.MaxDepth}, MaxElements={options.MaxElements}, PID={options.TargetProcessId?.ToString() ?? "auto"}");

        var watcher = new WinEventProfileMenuWatcher();
        var result = watcher.Watch(
            timeoutSeconds,
            options.TargetProcessId,
            options.MaxDepth,
            options.MaxElements
        );

        // Print diagnostics
        foreach (var msg in result.Diagnostics)
        {
            ConsoleLogger.Info($"[Diag] {msg}");
        }

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("            PROFILE MENU WINEVENT WATCH REPORT                                  ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        // 1. Events summary
        Console.WriteLine($"1. Total Events Captured: {result.Events.Count}");
        Console.WriteLine();

        if (result.Events.Count > 0)
        {
            // Group by event type
            var grouped = result.Events.GroupBy(e => e.EventName).OrderByDescending(g => g.Count());
            Console.WriteLine("   Event Type Breakdown:");
            foreach (var g in grouped)
            {
                Console.WriteLine($"     {g.Key,-32}: {g.Count()} event(s)");
            }
            Console.WriteLine();

            // Show all events chronologically (capped at 100 for readability)
            Console.WriteLine("   Chronological Event Log (max 100 shown):");
            var eventsToShow = result.Events.Take(100).ToList();
            foreach (var evt in eventsToShow)
            {
                var boundsStr = evt.Bounds != null ? $"{evt.Bounds.X},{evt.Bounds.Y} {evt.Bounds.Width}x{evt.Bounds.Height}" : "n/a";
                Console.WriteLine($"     [{evt.Timestamp:HH:mm:ss.fff}] {evt.EventName,-28} HWND=0x{evt.Hwnd.ToInt64():X8} PID={evt.ProcessId,-6} Visible={evt.IsVisible,-5} Class='{evt.WindowClassName}' Title='{evt.WindowTitle}' Bounds=({boundsStr})");
            }
            if (result.Events.Count > 100)
            {
                Console.WriteLine($"     ... ({result.Events.Count - 100} more events omitted)");
            }
            Console.WriteLine();

            // Highlight significant events (visible windows created/shown)
            var significant = result.Events
                .Where(e => e.IsVisible
                    && e.Bounds is { Width: > 10, Height: > 10 }
                    && e.EventName is "EVENT_OBJECT_CREATE" or "EVENT_OBJECT_SHOW" or "EVENT_SYSTEM_MENUPOPUPSTART")
                .ToList();

            Console.WriteLine($"   Significant Popup/Create Events (visible, non-trivial size): {significant.Count}");
            foreach (var evt in significant)
            {
                var boundsStr = evt.Bounds != null ? $"{evt.Bounds.X},{evt.Bounds.Y} {evt.Bounds.Width}x{evt.Bounds.Height}" : "n/a";
                Console.WriteLine($"     >>> {evt.EventName,-28} HWND=0x{evt.Hwnd.ToInt64():X8} PID={evt.ProcessId} Class='{evt.WindowClassName}' Title='{evt.WindowTitle}' Bounds=({boundsStr})");
            }
            Console.WriteLine();
        }

        // 2. Extracted text labels
        Console.WriteLine($"2. Extracted Text Labels ({result.ExtractedTexts.Count}):");
        if (result.ExtractedTexts.Count == 0)
        {
            Console.WriteLine("   (No text labels extracted)");
        }
        else
        {
            foreach (var txt in result.ExtractedTexts)
            {
                Console.WriteLine($"   - \"{txt}\"");
            }
        }
        Console.WriteLine();

        // 3. Captured UIA trees
        Console.WriteLine($"3. Captured UI Automation Trees ({result.CapturedTrees.Count}):");
        if (result.CapturedTrees.Count == 0)
        {
            Console.WriteLine("   (No UIA trees captured — the popup may use custom rendering)");
        }
        else
        {
            for (int i = 0; i < result.CapturedTrees.Count; i++)
            {
                var tree = result.CapturedTrees[i];
                Console.WriteLine($"--- Captured Tree #{i + 1} [{tree.ControlType}: '{tree.Name}' (HWND: 0x{tree.NativeWindowHandle.ToInt64():X}, Class: '{tree.ClassName}')] ---");
                PrintElementRecursive(tree, 0);
                Console.WriteLine();
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
