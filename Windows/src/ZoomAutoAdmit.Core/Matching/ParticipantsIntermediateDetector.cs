using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public static class ParticipantsIntermediateDetector
{
    private static readonly Regex TapForParticipantsRegex = new(
        @"\btap\s+(for|to\s+view|to\s+open)?\s*participants\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex ToolbarParticipantsRegex = new(
        @"^participants(\s*\(\d+\))?$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex CodeNoiseRegex = new(
        @"\b(class|public|private|var|int|string|import|function|const|let|return|void|namespace|using)\b|[{}<>;]",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static ParticipantsIntermediateCandidate Detect(
        OcrResult ocr,
        ParticipantsPanelDetectionResult? panel = null)
    {
        var reasons = new List<string>();

        // 1. Look for explicit "Tap for Participants"
        foreach (var line in ocr.Lines)
        {
            string text = line.Text.Trim();
            if (CodeNoiseRegex.IsMatch(text)) continue;

            if (TapForParticipantsRegex.IsMatch(text))
            {
                var center = (line.Bounds.X + line.Bounds.Width / 2.0, line.Bounds.Y + line.Bounds.Height / 2.0);
                return new ParticipantsIntermediateCandidate
                {
                    Kind = ParticipantsIntermediateKind.TapForParticipants,
                    Line = line,
                    ActionBounds = line.Bounds,
                    ActionCenter = center,
                    Confidence = 0.99,
                    IsAccepted = true,
                    SourceDescription = "TapForParticipantsBanner",
                    Reasons = ["Explicit 'Tap for Participants' phrase detected."]
                };
            }
        }

        // 2. Look for Zoom toolbar "Participants" control (only if panel is not already open)
        if (panel == null || !panel.IsPanelVisible)
        {
            foreach (var line in ocr.Lines)
            {
                string text = line.Text.Trim();
                if (CodeNoiseRegex.IsMatch(text)) continue;

                if (ToolbarParticipantsRegex.IsMatch(text))
                {
                    // Avoid huge text or full document blocks
                    if (line.Bounds.Height > 60 || line.Bounds.Width > 300) continue;

                    var center = (line.Bounds.X + line.Bounds.Width / 2.0, line.Bounds.Y + line.Bounds.Height / 2.0);
                    return new ParticipantsIntermediateCandidate
                    {
                        Kind = ParticipantsIntermediateKind.ToolbarParticipantsButton,
                        Line = line,
                        ActionBounds = line.Bounds,
                        ActionCenter = center,
                        Confidence = 0.95,
                        IsAccepted = true,
                        SourceDescription = "ZoomToolbarParticipantsButton",
                        Reasons = ["Zoom toolbar 'Participants' action button detected."]
                    };
                }
            }
        }

        return new ParticipantsIntermediateCandidate
        {
            Kind = ParticipantsIntermediateKind.None,
            Confidence = 0.0,
            IsAccepted = false,
            Reasons = ["No intermediate 'Tap for Participants' or toolbar control detected."]
        };
    }
}
