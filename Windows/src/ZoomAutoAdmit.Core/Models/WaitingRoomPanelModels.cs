namespace ZoomAutoAdmit.Core.Models;

public sealed class WaitingParticipantRowCandidate
{
    public string RawText { get; init; } = string.Empty;
    public string ParticipantName { get; init; } = string.Empty;
    public string MonitorName { get; set; } = string.Empty;
    public BoundingRectangleInfo MonitorBounds { get; set; } = BoundingRectangleInfo.Empty;
    public BoundingRectangleInfo TextBounds { get; init; } = BoundingRectangleInfo.Empty;
    public BoundingRectangleInfo RowBounds { get; init; } = BoundingRectangleInfo.Empty;
    public (double X, double Y) SafeHoverPoint { get; init; }
    public double Confidence { get; init; }
}

public sealed class ParticipantsPanelDetectionResult
{
    public bool IsPanelVisible { get; init; }
    public OcrLine? ParticipantsHeader { get; init; }
    public OcrLine? WaitingRoomHeader { get; init; }
    public OcrLine? JoinedHeader { get; init; }
    public int? DeclaredWaitingCount { get; init; }
    public BoundingRectangleInfo PanelBounds { get; init; } = BoundingRectangleInfo.Empty;
    public IReadOnlyList<WaitingParticipantRowCandidate> Rows { get; init; } = Array.Empty<WaitingParticipantRowCandidate>();
    public IReadOnlyList<string> RejectionReasons { get; init; } = Array.Empty<string>();
    public bool HasActiveWaitingParticipants =>
        (DeclaredWaitingCount.GetValueOrDefault(0) > 0) ||
        (DeclaredWaitingCount == null && WaitingRoomHeader != null && Rows.Count > 0);
}

public sealed class HoverAdmitValidationResult
{
    public bool IsConfirmed { get; init; }
    public WaitingParticipantRowCandidate? Row { get; init; }
    public OcrWord? AdmitWord { get; init; }
    public (double X, double Y) AdmitCenter { get; init; }
    public double Confidence { get; init; }
    public IReadOnlyList<string> RejectionReasons { get; init; } = Array.Empty<string>();
}

public sealed class PostHoverAdmitEvaluation
{
    public OcrWord AdmitWord { get; init; } = new(string.Empty, BoundingRectangleInfo.Empty);
    public BoundingRectangleInfo ExpandedRowBounds { get; init; } = BoundingRectangleInfo.Empty;
    public bool InsidePanel { get; init; }
    public bool InsideExpandedRow { get; init; }
    public bool RightOfParticipant { get; init; }
    public bool AboveJoined { get; init; }
    public bool IsAdmitAll { get; init; }
    public bool IsToastAdmit { get; init; }
    public bool IsAccepted { get; init; }
    public string RejectionReason { get; init; } = string.Empty;
}

public enum PanelAdmissionVerificationKind
{
    Pending,
    Verified
}

public sealed record PanelAdmissionVerificationResult(
    PanelAdmissionVerificationKind Kind,
    string Reason);
