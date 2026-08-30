using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.Inspector.Commands;

/// <summary>
/// Read-only UI Automation inspection rooted at one native window handle.
/// It also includes visible top-level windows owned by the same process so
/// transient Zoom profile and Switch Account popup windows can be captured.
/// </summary>
public static class UiaHwndInspectCommand
{
    public static int Execute(CliOptions options)
    {
        if (!options.TargetWindowHandle.HasValue)
        {
            ConsoleLogger.Error("uia-hwnd-inspect requires --hwnd <decimal|0xHEX>.");
            return 1;
        }

        var targetHandle = new IntPtr(options.TargetWindowHandle.Value);
        if (!NativeMethods.IsWindow(targetHandle))
        {
            ConsoleLogger.Error($"HWND 0x{targetHandle.ToInt64():X} is not a valid window.");
            return 1;
        }

        NativeMethods.GetWindowThreadProcessId(targetHandle, out uint targetProcessId);
        ConsoleLogger.Info($"Read-only UIA inspection target: HWND=0x{targetHandle.ToInt64():X}, PID={targetProcessId}.");
        if (options.DelaySeconds > 0)
        {
            ConsoleLogger.Info($"Waiting {options.DelaySeconds} second(s). Open the Zoom profile/Switch Account menu now.");
            Thread.Sleep(TimeSpan.FromSeconds(options.DelaySeconds));
        }

        int visited = 0;
        bool truncated = false;
        int rootCount = 0;

        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            using var automation = new UIA3Automation();
            var handles = GetRelatedVisibleWindows(targetHandle, targetProcessId);

            Console.WriteLine();
            Console.WriteLine("================================================================================");
            Console.WriteLine("                       ZOOM HWND UI AUTOMATION TREE");
            Console.WriteLine("================================================================================");

            foreach (var handle in handles)
            {
                if (visited >= options.MaxElements)
                {
                    truncated = true;
                    break;
                }

                try
                {
                    var root = automation.FromHandle(handle);
                    if (root == null) continue;
                    rootCount++;
                    string scope = handle == targetHandle ? "TARGET WINDOW" : "RELATED VISIBLE WINDOW / POPUP";
                    Console.WriteLine();
                    Console.WriteLine($"--- {scope}: HWND=0x{handle.ToInt64():X} ---");
                    PrintTree(root, 0, options.MaxDepth, options.MaxElements, ref visited, ref truncated);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[UIA ERROR] HWND=0x{handle.ToInt64():X}: {ex.Message}");
                }
            }
        });

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine($"Roots inspected : {rootCount}");
        Console.WriteLine($"Elements printed: {visited}");
        Console.WriteLine($"Truncated       : {(truncated ? "YES" : "No")}");
        Console.WriteLine("Read-only inspection: no element was invoked or clicked.");
        Console.WriteLine("================================================================================");
        return rootCount > 0 ? 0 : 1;
    }

    private static IReadOnlyList<IntPtr> GetRelatedVisibleWindows(IntPtr targetHandle, uint targetProcessId)
    {
        var handles = new List<IntPtr> { targetHandle };
        NativeMethods.EnumWindows((handle, _) =>
        {
            if (handle != targetHandle && NativeMethods.IsWindowVisible(handle))
            {
                NativeMethods.GetWindowThreadProcessId(handle, out uint processId);
                if (processId == targetProcessId) handles.Add(handle);
            }
            return true;
        }, IntPtr.Zero);
        return handles.Distinct().ToArray();
    }

    private static void PrintTree(
        AutomationElement element,
        int depth,
        int maxDepth,
        int maxElements,
        ref int visited,
        ref bool truncated)
    {
        if (visited >= maxElements)
        {
            truncated = true;
            return;
        }

        visited++;
        string indent = new(' ', depth * 2);
        try
        {
            string name = element.Properties.Name.ValueOrDefault ?? string.Empty;
            string controlType = element.Properties.ControlType.ValueOrDefault.ToString();
            string automationId = element.Properties.AutomationId.ValueOrDefault ?? string.Empty;
            string className = element.Properties.ClassName.ValueOrDefault ?? string.Empty;
            var bounds = element.Properties.BoundingRectangle.ValueOrDefault;
            Console.WriteLine($"{indent}Name: {Quote(name)}");
            Console.WriteLine($"{indent}ControlType: {controlType}");
            Console.WriteLine($"{indent}AutomationId: {Quote(automationId)}");
            Console.WriteLine($"{indent}ClassName: {Quote(className)}");
            Console.WriteLine($"{indent}BoundingRectangle: [{bounds.X:F0},{bounds.Y:F0},{bounds.Width:F0}x{bounds.Height:F0}]");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"{indent}[UIA PROPERTY ERROR] {ex.Message}");
        }

        if (depth >= maxDepth) return;
        try
        {
            foreach (var child in element.FindAllChildren())
            {
                PrintTree(child, depth + 1, maxDepth, maxElements, ref visited, ref truncated);
                if (visited >= maxElements) break;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"{indent}[UIA CHILD ERROR] {ex.Message}");
        }
    }

    private static string Quote(string value) => $"'{value.Replace("'", "''")}'";
}
