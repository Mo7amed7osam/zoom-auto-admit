using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.UIAutomation.Discovery;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class ProcessesCommand
{
    public static int Execute()
    {
        ConsoleLogger.Info("Enumerating candidate Zoom processes and associated top-level windows...");

        var discovery = new ZoomProcessDiscovery();
        var candidates = discovery.FindCandidates();

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("                        ZOOM PROCESS CANDIDATES                                 ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        if (candidates.Count == 0)
        {
            Console.WriteLine("No Zoom processes found running on this system.");
            Console.WriteLine("Please ensure Zoom Workplace is running.");
            return 1;
        }

        foreach (var c in candidates)
        {
            Console.WriteLine($"[PID: {c.ProcessId}] {c.ProcessName}");
            Console.WriteLine($"  Executable Path   : {c.ExecutablePath ?? "(Access Denied / Not Available)"}");
            Console.WriteLine($"  Main Window Handle: 0x{c.MainWindowHandle.ToInt64():X}");
            Console.WriteLine($"  Main Window Title : {(string.IsNullOrEmpty(c.MainWindowTitle) ? "(empty)" : c.MainWindowTitle)}");
            Console.WriteLine($"  UIA Accessible    : {c.IsAccessible}");
            Console.WriteLine($"  Windows ({c.Windows.Count}):");

            foreach (var w in c.Windows)
            {
                var vis = w.IsVisible ? "Visible" : "Hidden";
                var title = string.IsNullOrEmpty(w.Title) ? "(no title)" : $"'{w.Title}'";
                Console.WriteLine($"    - Handle: 0x{w.Handle.ToInt64():X} | {vis} | Class: {w.ClassName} | Title: {title} | Bounds: {w.Bounds}");
            }
            Console.WriteLine();
        }

        Console.WriteLine("================================================================================");
        return 0;
    }
}
