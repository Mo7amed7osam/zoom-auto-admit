namespace ZoomAutoAdmit.Core.Matching;

/// <summary>
/// Helper methods to identify meeting-related UI elements and Waiting Room controls
/// in the Windows UI Automation tree.
/// </summary>
public static class MeetingElementMatcher
{
    public static bool IsMeetingWindow(string? title, string? className)
    {
        var t = title ?? string.Empty;
        var c = className ?? string.Empty;

        if (c.StartsWith("ZPMeeting", StringComparison.OrdinalIgnoreCase) ||
            c.StartsWith("ZPFloatToolbar", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (t.IndexOf("Meeting", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("Zoom Meeting", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("Zoom Webinar", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return true;
        }

        return false;
    }

    public static bool IsParticipantsPanel(string? name, string? automationId, string? className, string? controlType)
    {
        var n = name ?? string.Empty;
        var a = automationId ?? string.Empty;
        var c = className ?? string.Empty;

        return n.IndexOf("Participant", StringComparison.OrdinalIgnoreCase) >= 0 ||
               a.IndexOf("Participant", StringComparison.OrdinalIgnoreCase) >= 0 ||
               c.IndexOf("Participant", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static bool IsWaitingRoomSection(string? name, string? legacyName)
    {
        var n = name ?? string.Empty;
        var l = legacyName ?? string.Empty;

        return n.IndexOf("Waiting Room", StringComparison.OrdinalIgnoreCase) >= 0 ||
               l.IndexOf("Waiting Room", StringComparison.OrdinalIgnoreCase) >= 0 ||
               n.IndexOf("Waiting", StringComparison.OrdinalIgnoreCase) >= 0 ||
               l.IndexOf("Waiting", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static bool IsAdmitButton(string? name, string? legacyName, string? controlType)
    {
        var n = (name ?? string.Empty).Trim();
        var l = (legacyName ?? string.Empty).Trim();

        // Exact or starts-with match for "Admit" (avoiding "Admit All" if separate)
        bool nameMatches = n.Equals("Admit", StringComparison.OrdinalIgnoreCase) ||
                           n.StartsWith("Admit ", StringComparison.OrdinalIgnoreCase) ||
                           n.EndsWith(" Admit", StringComparison.OrdinalIgnoreCase);

        bool legacyMatches = l.Equals("Admit", StringComparison.OrdinalIgnoreCase) ||
                             l.StartsWith("Admit ", StringComparison.OrdinalIgnoreCase);

        bool isButton = string.IsNullOrEmpty(controlType) ||
                        controlType.Equals("Button", StringComparison.OrdinalIgnoreCase) ||
                        controlType.Equals("SplitButton", StringComparison.OrdinalIgnoreCase) ||
                        controlType.Equals("MenuItem", StringComparison.OrdinalIgnoreCase);

        return (nameMatches || legacyMatches) && isButton;
    }

    public static bool IsAdmitAllButton(string? name, string? legacyName, string? controlType)
    {
        var n = (name ?? string.Empty).Trim();
        var l = (legacyName ?? string.Empty).Trim();

        bool matches = n.IndexOf("Admit all", StringComparison.OrdinalIgnoreCase) >= 0 ||
                       l.IndexOf("Admit all", StringComparison.OrdinalIgnoreCase) >= 0 ||
                       n.IndexOf("Admit All", StringComparison.OrdinalIgnoreCase) >= 0;

        return matches;
    }
}
