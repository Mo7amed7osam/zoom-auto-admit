using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class InspectCommand
{
    public static int Execute(CliOptions options)
    {
        ConsoleLogger.Info("Starting Zoom UI Automation tree inspection (Read-Only)...");
        ConsoleLogger.Info($"Options: MaxDepth={options.MaxDepth}, MaxElements={options.MaxElements}, TargetPID={(options.TargetProcessId.HasValue ? options.TargetProcessId.Value.ToString() : "auto-detect")}");

        using var inspector = new ZoomTreeInspector();
        var (roots, summary) = inspector.Inspect(options.ToInspectionOptions());

        if (roots.Count == 0)
        {
            ConsoleLogger.Warn("No UI Automation elements discovered. Is Zoom Workplace running?");
            return 1;
        }

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("                        ZOOM UI AUTOMATION TREE                                ");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        for (int i = 0; i < roots.Count; i++)
        {
            Console.WriteLine($"--- Root Window #{i + 1} ---");
            Console.WriteLine(ElementFormatter.FormatTree(roots[i]));
            Console.WriteLine();
        }

        Console.WriteLine("================================================================================");
        Console.WriteLine("                         INSPECTION SUMMARY                                     ");
        Console.WriteLine("================================================================================");
        Console.WriteLine($"Total Elements Visited : {summary.TotalElementsVisited}");
        Console.WriteLine($"Max Depth Reached      : {summary.MaxDepthReached}");
        Console.WriteLine($"Depth Truncated        : {(summary.DepthTruncated ? "YES (reached max depth limit)" : "No")}");
        Console.WriteLine($"Count Truncated        : {(summary.ElementCountTruncated ? "YES (reached max elements limit)" : "No")}");
        Console.WriteLine($"Elapsed Time           : {summary.ElapsedTime.TotalMilliseconds:F1} ms");

        if (summary.DiagnosticWarnings.Count > 0)
        {
            Console.WriteLine();
            Console.WriteLine("Diagnostic Warnings:");
            foreach (var w in summary.DiagnosticWarnings)
            {
                Console.WriteLine($"  - {w}");
            }
        }
        Console.WriteLine("================================================================================");

        return 0;
    }
}
