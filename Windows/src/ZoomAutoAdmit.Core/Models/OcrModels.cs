namespace ZoomAutoAdmit.Core.Models;

/// <summary>
/// Represents an OCR-recognized word with its bounding box in screen coordinates.
/// </summary>
public record OcrWord(string Text, BoundingRectangleInfo Bounds)
{
    public (double X, double Y) Center => (Bounds.X + Bounds.Width / 2.0, Bounds.Y + Bounds.Height / 2.0);

    public override string ToString() => $"'{Text}' at {Bounds}";
}

/// <summary>
/// Represents an OCR-recognized line of text composed of individual words and an overall bounding box.
/// </summary>
public record OcrLine(string Text, BoundingRectangleInfo Bounds, IReadOnlyList<OcrWord> Words)
{
    public override string ToString() => $"'{Text}' ({Words.Count} words) at {Bounds}";
}

/// <summary>
/// Represents the aggregate result of an OCR recognition operation over a screen or image region.
/// </summary>
public record OcrResult(
    IReadOnlyList<OcrLine> Lines,
    IReadOnlyList<OcrWord> Words,
    BoundingRectangleInfo ImageBounds)
{
    public static OcrResult Empty => new(
        Array.Empty<OcrLine>(),
        Array.Empty<OcrWord>(),
        BoundingRectangleInfo.Empty);
}

/// <summary>
/// Represents an evaluated candidate for the Zoom Waiting Room notification toast.
/// </summary>
public class WaitingRoomToastCandidate
{
    public string? ParticipantName { get; set; }
    public string ParticipantRawText { get; set; } = string.Empty;
    public string ParticipantNormalizedName { get; set; } = string.Empty;
    public string MonitorName { get; set; } = string.Empty;
    public BoundingRectangleInfo MonitorBounds { get; set; } = BoundingRectangleInfo.Empty;
    public WaitingRoomNotificationLayout LayoutType { get; set; }
    public BoundingRectangleInfo ToastBounds { get; set; } = BoundingRectangleInfo.Empty;
    public OcrWord? AdmitWord { get; set; }
    public OcrWord? ViewWord { get; set; }
    public OcrLine? HeaderLine { get; set; }
    public (double X, double Y) AdmitCenter { get; set; }
    public double Confidence { get; set; }
    public bool IsAccepted { get; set; }
    public List<string> AcceptanceReasons { get; } = new();
    public List<string> RejectionReasons { get; } = new();
    public BoundingRectangleInfo AdmitBounds => AdmitWord?.Bounds ?? BoundingRectangleInfo.Empty;
    public BoundingRectangleInfo ViewBounds => ViewWord?.Bounds ?? BoundingRectangleInfo.Empty;
    public IReadOnlyList<string> DetectionReasons => AcceptanceReasons.Concat(RejectionReasons).ToList();

    public override string ToString() =>
        $"Candidate [Accepted={IsAccepted}, Conf={Confidence:P0}, Participant='{ParticipantName}', AdmitCenter=({AdmitCenter.X:F0},{AdmitCenter.Y:F0})]";
}

public enum WaitingRoomNotificationLayout
{
    Unknown,
    InMeetingToast,
    WindowsNotification,
    MultiPersonNotification
}

/// <summary>
/// Represents the final result of toast detection across the desktop OCR scan.
/// </summary>
public class WaitingRoomToastDetectionResult
{
    public bool IsDetected => BestCandidate != null && BestCandidate.IsAccepted;
    public WaitingRoomToastCandidate? BestCandidate { get; set; }
    public IReadOnlyList<WaitingRoomToastCandidate> AllCandidates { get; set; } = Array.Empty<WaitingRoomToastCandidate>();
    public IReadOnlyList<OcrWord> AllAdmitWordsFound { get; set; } = Array.Empty<OcrWord>();
    public IReadOnlyList<OcrWord> AllViewWordsFound { get; set; } = Array.Empty<OcrWord>();
    public IReadOnlyList<OcrLine> AllWaitingRoomLinesFound { get; set; } = Array.Empty<OcrLine>();
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
    public TimeSpan ScanDuration { get; set; }

    public static WaitingRoomToastDetectionResult Empty => new();
}
