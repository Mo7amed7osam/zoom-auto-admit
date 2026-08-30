using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class AccountMenuInspectCommand
{
    public static int Execute(CliOptions options)
    {
        ConsoleLogger.Info("Starting controlled Account Menu Diagnostic Inspection...");
        ConsoleLogger.Info("Verifying Profile SplitButton before executing InvokePattern...");

        var inspector = new AccountMenuInspector();
        var result = inspector.InspectAccountMenu(options.TargetProcessId);

        foreach (var msg in result.DiagnosticMessages)
        {
            ConsoleLogger.Info($"[Diag] {msg}");
        }

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("                    ACCOUNT MENU DIAGNOSTIC REPORT                              ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();
        Console.WriteLine($"1. Foreground BEFORE Invocation:");
        Console.WriteLine($"   HWND: 0x{result.ForegroundBefore.Handle.ToInt64():X} | PID: {result.ForegroundBefore.ProcessId} | Process: '{result.ForegroundBefore.ProcessName}' | Title: '{result.ForegroundBefore.WindowTitle}'");
        Console.WriteLine();

        if (result.ProfileButton != null)
        {
            Console.WriteLine($"2. Verified & Invoked Profile Element:");
            Console.WriteLine($"   ControlType: {result.ProfileButton.ControlType}");
            Console.WriteLine($"   Name: {result.ProfileButton.Name}");
            Console.WriteLine($"   ProcessId: {result.ProfileButton.ProcessId}");
            Console.WriteLine($"   BoundingRectangle: {result.ProfileButton.BoundingRectangle}");
            Console.WriteLine($"   InvokePattern: {(result.ProfileButton.Patterns.HasInvoke ? "Supported" : "NOT supported")}");
        }
        else
        {
            Console.WriteLine($"2. Verified Profile Element: NOT FOUND (Action aborted)");
        }
        Console.WriteLine();

        Console.WriteLine($"3. Foreground AFTER Invocation:");
        Console.WriteLine($"   HWND: 0x{result.ForegroundAfter.Handle.ToInt64():X} | PID: {result.ForegroundAfter.ProcessId} | Process: '{result.ForegroundAfter.ProcessName}' | Title: '{result.ForegroundAfter.WindowTitle}'");
        Console.WriteLine();
        Console.WriteLine($"4. Focus Stolen by Zoom: {(result.StoleFocus ? "YES" : "NO (Focus preserved)")}");
        Console.WriteLine();

        Console.WriteLine($"5. Discovered Popup Windows ({result.DiscoveredPopupWindows.Count}):");
        foreach (var win in result.DiscoveredPopupWindows)
        {
            Console.WriteLine($"   - HWND: 0x{win.Handle.ToInt64():X} | Class: {win.ClassName} | Title: '{win.Title}' | Bounds: {win.Bounds}");
        }
        Console.WriteLine();

        Console.WriteLine($"6. Popup UIA Hierarchy ({result.PopupTrees.Count} tree(s)):");
        if (result.PopupTrees.Count == 0)
        {
            Console.WriteLine("   (No popup UIA elements discovered)");
        }
        else
        {
            foreach (var tree in result.PopupTrees)
            {
                PrintElementRecursive(tree, 1);
            }
        }

        Console.WriteLine();
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
