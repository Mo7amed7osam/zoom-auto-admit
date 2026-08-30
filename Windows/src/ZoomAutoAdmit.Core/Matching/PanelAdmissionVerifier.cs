using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

/// <summary>
/// Requires two fresh post-click captures showing that the original participant
/// left Waiting Room. A transient hover-button change is never sufficient.
/// </summary>
public sealed class PanelAdmissionVerifier
{
    private readonly string _participant;
    private readonly int _originalWaitingCount;
    private readonly BoundingRectangleInfo _originalRowBounds;
    private readonly BoundingRectangleInfo _participantsHeaderBounds;
    private int _consecutiveSuccesses;

    public PanelAdmissionVerifier(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel)
    {
        _participant = Normalize(originalRow.ParticipantName);
        _originalWaitingCount = originalPanel.DeclaredWaitingCount ?? originalPanel.Rows.Count;
        _originalRowBounds = originalRow.RowBounds;
        _participantsHeaderBounds = originalPanel.ParticipantsHeader?.Bounds ?? BoundingRectangleInfo.Empty;
    }

    public PanelAdmissionVerificationResult Observe(ParticipantsPanelDetectionResult current)
    {
        bool waitingSectionGone = current.ParticipantsHeader != null &&
                                  current.WaitingRoomHeader == null &&
                                  SameHeaderNeighborhood(current.ParticipantsHeader.Bounds, _participantsHeaderBounds);
        bool participantStillPresent = current.Rows.Any(row =>
            Normalize(row.ParticipantName).Equals(_participant, StringComparison.OrdinalIgnoreCase));
        bool originalRowStillPresent = current.Rows.Any(row => VerticalOverlap(row.RowBounds, _originalRowBounds) >= 0.60);
        int currentCount = current.DeclaredWaitingCount ?? current.Rows.Count;
        bool countDecreasedAndRowGone = current.IsPanelVisible &&
                                        currentCount < _originalWaitingCount &&
                                        !originalRowStillPresent;
        bool successEvidence = waitingSectionGone ||
                               (current.IsPanelVisible && !participantStillPresent) ||
                               countDecreasedAndRowGone;

        _consecutiveSuccesses = successEvidence ? _consecutiveSuccesses + 1 : 0;
        if (_consecutiveSuccesses >= 2)
        {
            return new PanelAdmissionVerificationResult(
                PanelAdmissionVerificationKind.Verified,
                "The original participant is absent from Waiting Room in two consecutive captures.");
        }

        return new PanelAdmissionVerificationResult(
            PanelAdmissionVerificationKind.Pending,
            participantStillPresent
                ? "The original participant remains in Waiting Room; hover-button disappearance is not admission evidence."
                : "One matching post-click absence frame observed; a second consecutive capture is required.");
    }

    private static string Normalize(string value) =>
        string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();

    private static double VerticalOverlap(BoundingRectangleInfo first, BoundingRectangleInfo second)
    {
        double top = Math.Max(first.Y, second.Y);
        double bottom = Math.Min(first.Y + first.Height, second.Y + second.Height);
        double overlap = Math.Max(0, bottom - top);
        double minimumHeight = Math.Min(first.Height, second.Height);
        return minimumHeight <= 0 ? 0 : overlap / minimumHeight;
    }

    private static bool SameHeaderNeighborhood(BoundingRectangleInfo current, BoundingRectangleInfo original)
    {
        if (current.Width <= 0 || current.Height <= 0 || original.Width <= 0 || original.Height <= 0) return false;
        double dx = Math.Abs((current.X + current.Width / 2.0) - (original.X + original.Width / 2.0));
        double dy = Math.Abs((current.Y + current.Height / 2.0) - (original.Y + original.Height / 2.0));
        return dx <= 40 && dy <= 30;
    }
}
