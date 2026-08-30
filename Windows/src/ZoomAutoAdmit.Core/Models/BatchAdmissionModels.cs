namespace ZoomAutoAdmit.Core.Models;

public sealed class MultiPersonWaitingNotificationCandidate
{
    public int WaitingCount { get; init; }
    public string MonitorName { get; set; } = string.Empty;
    public BoundingRectangleInfo MonitorBounds { get; set; } = BoundingRectangleInfo.Empty;
    public OcrLine? HeaderLine { get; init; }
    public OcrWord? ViewWord { get; init; }
    public BoundingRectangleInfo NotificationBounds { get; init; } = BoundingRectangleInfo.Empty;
    public (double X, double Y) ViewCenter { get; init; }
    public double Confidence { get; init; }
    public bool IsAccepted { get; init; }
    public IReadOnlyList<string> DetectionReasons { get; init; } = Array.Empty<string>();
}

public sealed class MultiPersonWaitingDetectionResult
{
    public IReadOnlyList<MultiPersonWaitingNotificationCandidate> AllCandidates { get; init; } =
        Array.Empty<MultiPersonWaitingNotificationCandidate>();
}

public sealed class PanelAdmitAllCandidate
{
    public ParticipantsPanelDetectionResult Panel { get; init; } = new();
    public string MonitorName { get; set; } = string.Empty;
    public BoundingRectangleInfo MonitorBounds { get; set; } = BoundingRectangleInfo.Empty;
    public OcrLine? AdmitAllLine { get; init; }
    public BoundingRectangleInfo AdmitAllBounds { get; init; } = BoundingRectangleInfo.Empty;
    public (double X, double Y) AdmitAllCenter { get; init; }
    public int? WaitingCount { get; init; }
    public IReadOnlyList<string> OriginalParticipants { get; init; } = Array.Empty<string>();
    public double Confidence { get; init; }
    public bool IsAccepted { get; init; }
    public IReadOnlyList<string> DetectionReasons { get; init; } = Array.Empty<string>();
}

public enum BatchAdmissionVerificationKind
{
    Pending,
    Verified
}

public sealed record BatchAdmissionVerificationResult(
    BatchAdmissionVerificationKind Kind,
    string Reason);
