using System.Text.RegularExpressions;

namespace ZoomAutoAdmit.WebAutomation;

public static class WebParticipantIdentity
{
    private static readonly Regex ActionTextPattern = new(
        @"\b(?:Admit\s+all|Admit|View|More|Message|Remove|Mute|Unmute)\b|\.{3}",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex WaitingHeaderPattern = new(
        @"\bWaiting\s+room(?:\s*\(\d+\)|\s+\d+)?",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string FromRowText(string rowText)
    {
        string compact = string.Join(" ", rowText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        compact = WaitingHeaderPattern.Replace(compact, string.Empty);
        compact = ActionTextPattern.Replace(compact, string.Empty);
        int guestIndex = compact.IndexOf("(Guest)", StringComparison.OrdinalIgnoreCase);
        if (guestIndex >= 0) compact = compact[..guestIndex];
        return string.Join(" ", compact.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    public static string Normalize(string name) =>
        string.Join(" ", name.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim().ToUpperInvariant();
}
