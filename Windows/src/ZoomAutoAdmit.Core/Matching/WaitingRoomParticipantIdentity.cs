using System.Text.RegularExpressions;

namespace ZoomAutoAdmit.Core.Matching;

public sealed record WaitingRoomParticipantIdentity(string RawText, string NormalizedName)
{
    private static readonly Regex VerifiedSplitSuffix = new(
        @"^(?<name>.+?)\s+(?:has\s+)?entered\s+the$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// <summary>
    /// Normalizes only the structural suffix produced by the verified split OCR
    /// layout: "&lt;name&gt; entered the" followed by a separate "waiting room" line.
    /// This runs after toast detection and cannot affect candidate acceptance.
    /// </summary>
    public static WaitingRoomParticipantIdentity FromAcceptedCandidateText(string? rawText)
    {
        string raw = rawText?.Trim() ?? string.Empty;
        var match = VerifiedSplitSuffix.Match(raw);
        string normalized = match.Success ? match.Groups["name"].Value.Trim() : raw;
        return new WaitingRoomParticipantIdentity(raw, normalized);
    }
}
