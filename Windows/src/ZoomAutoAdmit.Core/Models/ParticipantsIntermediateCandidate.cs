namespace ZoomAutoAdmit.Core.Models;

public enum ParticipantsIntermediateKind
{
    None,
    TapForParticipants,
    ToolbarParticipantsButton
}

public sealed class ParticipantsIntermediateCandidate
{
    public ParticipantsIntermediateKind Kind { get; set; }
    public OcrLine? Line { get; set; }
    public BoundingRectangleInfo ActionBounds { get; set; } = BoundingRectangleInfo.Empty;
    public (double X, double Y) ActionCenter { get; set; }
    public double Confidence { get; set; }
    public bool IsAccepted { get; set; }
    public string SourceDescription { get; set; } = string.Empty;
    public List<string> Reasons { get; set; } = [];
}
