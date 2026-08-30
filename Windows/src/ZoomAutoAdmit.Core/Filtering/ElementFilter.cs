using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Filtering;

public static class ElementFilter
{
    public static bool Matches(InspectElementInfo element, string? query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return true;
        }

        var trimmed = query.Trim();

        if (ContainsIgnoreCase(element.Name, trimmed)) return true;
        if (ContainsIgnoreCase(element.AutomationId, trimmed)) return true;
        if (ContainsIgnoreCase(element.ClassName, trimmed)) return true;
        if (ContainsIgnoreCase(element.ControlType, trimmed)) return true;

        return false;
    }

    public static List<InspectElementInfo> FindMatches(InspectElementInfo root, string query)
    {
        var matches = new List<InspectElementInfo>();
        CollectMatches(root, query, matches);
        return matches;
    }

    private static void CollectMatches(InspectElementInfo current, string query, List<InspectElementInfo> matches)
    {
        if (Matches(current, query))
        {
            matches.Add(current);
        }

        foreach (var child in current.Children)
        {
            CollectMatches(child, query, matches);
        }
    }

    private static bool ContainsIgnoreCase(string? source, string target)
    {
        if (string.IsNullOrEmpty(source)) return false;
        return source.IndexOf(target, StringComparison.OrdinalIgnoreCase) >= 0;
    }
}
