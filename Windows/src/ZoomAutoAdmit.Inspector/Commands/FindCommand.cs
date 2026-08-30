using ZoomAutoAdmit.Core.Filtering;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Inspection;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class FindCommand
{
    public static int Execute(CliOptions options)
    {
        if (string.IsNullOrWhiteSpace(options.Query))
        {
            ConsoleLogger.Error("No search term supplied. Usage: ZoomAutoAdmit.Inspector.exe find \"<term>\"");
            return 1;
        }

        ConsoleLogger.Info($"Searching Zoom UI Automation hierarchy for elements matching '{options.Query}'...");

        using var inspector = new ZoomTreeInspector();
        var (roots, summary) = inspector.Inspect(options.ToInspectionOptions());

        if (roots.Count == 0)
        {
            ConsoleLogger.Warn("No UI Automation hierarchy found. Is Zoom Workplace running?");
            return 1;
        }

        var matches = new List<Core.Models.InspectElementInfo>();
        foreach (var root in roots)
        {
            matches.AddRange(ElementFilter.FindMatches(root, options.Query));
        }

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine($"            SEARCH RESULTS FOR: \"{options.Query}\" ({matches.Count} match(es))");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        if (matches.Count == 0)
        {
            Console.WriteLine($"No elements found matching \"{options.Query}\".");
            Console.WriteLine($"Visited {summary.TotalElementsVisited} total elements.");
            return 0;
        }

        for (int i = 0; i < matches.Count; i++)
        {
            Console.WriteLine($"--- Match #{i + 1} (Depth {matches[i].Depth}) ---");
            Console.WriteLine(ElementFormatter.FormatSingleElement(matches[i]));
            Console.WriteLine();
        }

        Console.WriteLine("================================================================================");
        Console.WriteLine($"Found {matches.Count} match(es) across {summary.TotalElementsVisited} total element(s) visited.");
        Console.WriteLine("================================================================================");

        return 0;
    }
}
