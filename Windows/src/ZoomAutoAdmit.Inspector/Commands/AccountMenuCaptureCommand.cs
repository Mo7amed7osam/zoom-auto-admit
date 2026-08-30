using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class AccountMenuCaptureCommand
{
    public static int Execute(CliOptions options)
    {
        ConsoleLogger.Info("Starting Delayed Read-Only Account Menu Capture with Before/After Diff...");
        ConsoleLogger.Info($"Options: Delay={options.DelaySeconds}s, MaxDepth={options.MaxDepth}, MaxElements={options.MaxElements}, PID={options.TargetProcessId?.ToString() ?? "auto"}");

        var capturer = new DelayedAccountMenuCapturer();
        var result = capturer.Capture(
            options.DelaySeconds,
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
        Console.WriteLine("                DELAYED ACCOUNT MENU BEFORE/AFTER CAPTURE REPORT                ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        Console.WriteLine("1. Foreground Window at Capture:");
        Console.WriteLine($"   HWND: 0x{result.ForegroundWindow.Handle.ToInt64():X} | PID: {result.ForegroundWindow.ProcessId} | Process: '{result.ForegroundWindow.ProcessName}' | Title: '{result.ForegroundWindow.WindowTitle}'");
        Console.WriteLine();

        Console.WriteLine($"2. Baseline BEFORE Windows ({result.BeforeWindows.Count} total):");
        var visibleBefore = result.BeforeWindows.Where(w => w.IsVisible && w.Bounds.Width > 0).ToList();
        Console.WriteLine($"   Visible non-zero windows: {visibleBefore.Count}");
        foreach (var w in visibleBefore.Take(10))
        {
            Console.WriteLine($"   - HWND: 0x{w.Handle.ToInt64():X} | PID: {w.ProcessId} | Class: {w.ClassName,-30} | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }
        Console.WriteLine();

        Console.WriteLine($"3. State AFTER Windows ({result.AfterWindows.Count} total):");
        var visibleAfter = result.AfterWindows.Where(w => w.IsVisible && w.Bounds.Width > 0).ToList();
        Console.WriteLine($"   Visible non-zero windows: {visibleAfter.Count}");
        Console.WriteLine();

        Console.WriteLine("4. Window Diff Analysis:");
        Console.WriteLine($"   - Newly Created HWNDs ({result.DiffResult.NewWindows.Count}):");
        foreach (var w in result.DiffResult.NewWindows)
        {
            Console.WriteLine($"     * HWND: 0x{w.Handle.ToInt64():X} | PID: {w.ProcessId} | Visible: {w.IsVisible} | Class: {w.ClassName} | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }

        Console.WriteLine($"   - Changed from Hidden -> Visible ({result.DiffResult.BecameVisibleWindows.Count}):");
        foreach (var w in result.DiffResult.BecameVisibleWindows)
        {
            Console.WriteLine($"     * HWND: 0x{w.Handle.ToInt64():X} | PID: {w.ProcessId} | Class: {w.ClassName} | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }

        Console.WriteLine($"   - Resized from Zero -> Non-Zero ({result.DiffResult.ResizedToNonZeroWindows.Count}):");
        foreach (var w in result.DiffResult.ResizedToNonZeroWindows)
        {
            Console.WriteLine($"     * HWND: 0x{w.Handle.ToInt64():X} | PID: {w.ProcessId} | Class: {w.ClassName} | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }

        Console.WriteLine($"   - Primary Popup Candidate(s) ({result.DiffResult.PrimaryCandidates.Count}):");
        foreach (var w in result.DiffResult.PrimaryCandidates)
        {
            Console.WriteLine($"     >>> CANDIDATE HWND: 0x{w.Handle.ToInt64():X} | PID: {w.ProcessId} | Class: '{w.ClassName}' | Title: '{w.Title}' | Bounds: {w.Bounds}");
        }
        Console.WriteLine();

        Console.WriteLine($"5. Extracted Text Labels inside Captured Tree(s) ({result.ExtractedTexts.Count}):");
        foreach (var txt in result.ExtractedTexts)
        {
            Console.WriteLine($"   - \"{txt}\"");
        }
        Console.WriteLine();

        Console.WriteLine($"6. Captured UI Automation Trees ({result.PopupTrees.Count}):");
        if (result.PopupTrees.Count == 0)
        {
            Console.WriteLine("   (No UI Automation trees captured)");
        }
        else
        {
            for (int i = 0; i < result.PopupTrees.Count; i++)
            {
                var tree = result.PopupTrees[i];
                Console.WriteLine($"--- Root Tree #{i + 1} [{tree.ControlType}: '{tree.Name}' (HWND: 0x{tree.NativeWindowHandle.ToInt64():X}, Class: '{tree.ClassName}')] ---");
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

        foreach (var child in element.Children)
        {
            PrintElementRecursive(child, depth + 1);
        }
    }
}
