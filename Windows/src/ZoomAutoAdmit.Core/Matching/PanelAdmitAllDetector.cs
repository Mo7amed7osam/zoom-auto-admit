using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public static class PanelAdmitAllDetector
{
    public static PanelAdmitAllCandidate Detect(OcrResult ocr)
    {
        var panel = WaitingRoomParticipantRowDetector.Detect(ocr);
        var reasons = new List<string>();
        if (!panel.IsPanelVisible || panel.WaitingRoomHeader == null)
        {
            return new PanelAdmitAllCandidate
            {
                Panel = panel,
                DetectionReasons = ["Verified Participants / Waiting room panel is not visible."]
            };
        }

        var exactActions = ocr.Lines
            .Select(line => (Line: line, Bounds: FindExactAdmitAllBounds(line)))
            .Where(item => item.Bounds != null)
            .OrderBy(item => item.Line.Bounds.Y)
            .ToList();
        foreach (var action in exactActions)
        {
            var line = action.Line;
            var bounds = action.Bounds!;
            var center = (X: bounds.X + bounds.Width / 2.0, Y: bounds.Y + bounds.Height / 2.0);
            bool insidePanel = Contains(panel.PanelBounds, center);
            bool associatedWithWaiting = center.Y >= panel.WaitingRoomHeader.Bounds.Y - 12;
            bool aboveJoined = panel.JoinedHeader == null || center.Y < panel.JoinedHeader.Bounds.Y;
            bool countValid = !panel.DeclaredWaitingCount.HasValue || panel.DeclaredWaitingCount.Value > 0;
            if (!insidePanel || !associatedWithWaiting || !aboveJoined || !countValid) continue;

            reasons.Add("Exact 'Admit all' is inside the verified Participants panel.");
            reasons.Add("Admit all is scoped below Waiting room and above Joined.");
            if (panel.DeclaredWaitingCount.HasValue)
                reasons.Add($"OCR Waiting room count is {panel.DeclaredWaitingCount.Value}.");
            return new PanelAdmitAllCandidate
            {
                Panel = panel,
                AdmitAllLine = line,
                AdmitAllBounds = bounds,
                AdmitAllCenter = center,
                WaitingCount = panel.DeclaredWaitingCount,
                OriginalParticipants = panel.Rows.Select(row => Normalize(row.ParticipantName)).Where(name => name.Length > 0).ToList(),
                Confidence = 0.99,
                IsAccepted = true,
                DetectionReasons = reasons
            };
        }

        return new PanelAdmitAllCandidate
        {
            Panel = panel,
            WaitingCount = panel.DeclaredWaitingCount,
            OriginalParticipants = panel.Rows.Select(row => Normalize(row.ParticipantName)).ToList(),
            DetectionReasons = exactActions.Count == 0
                ? ["Exact 'Admit all' was not found."]
                : ["Admit all was outside the verified Waiting Room section geometry."]
        };
    }

    public static bool IsSameAction(PanelAdmitAllCandidate expected, PanelAdmitAllCandidate current) =>
        expected.IsAccepted && current.IsAccepted &&
        Distance(expected.AdmitAllCenter, current.AdmitAllCenter) <= AdmitOnceSafetyGate.CenterMovementTolerance &&
        IntersectionOverUnion(expected.Panel.PanelBounds, current.Panel.PanelBounds) >= AdmitOnceSafetyGate.MinimumToastOverlap;

    private static BoundingRectangleInfo? FindExactAdmitAllBounds(OcrLine line)
    {
        var words = line.Words.OrderBy(word => word.Bounds.X).ToList();
        for (int index = 0; index < words.Count; index++)
        {
            if (Normalize(words[index].Text).Equals("Admit all", StringComparison.OrdinalIgnoreCase))
                return words[index].Bounds;
            if (!Normalize(words[index].Text).Equals("Admit", StringComparison.OrdinalIgnoreCase) || index + 1 >= words.Count)
                continue;
            var all = words[index + 1];
            double gap = all.Bounds.X - (words[index].Bounds.X + words[index].Bounds.Width);
            double dy = Math.Abs(all.Bounds.Y - words[index].Bounds.Y);
            if (Normalize(all.Text).Equals("all", StringComparison.OrdinalIgnoreCase) && gap >= -2 && gap <= 40 && dy <= 10)
                return Union([words[index].Bounds, all.Bounds]);
        }
        return null;
    }

    private static string Normalize(string value) => Regex.Replace(value.Trim(), @"\s+", " ");
    private static bool Contains(BoundingRectangleInfo bounds, (double X, double Y) point) =>
        point.X >= bounds.X && point.X <= bounds.X + bounds.Width &&
        point.Y >= bounds.Y && point.Y <= bounds.Y + bounds.Height;
    private static BoundingRectangleInfo Union(IEnumerable<BoundingRectangleInfo> values)
    {
        var list = values.ToList();
        double left = list.Min(value => value.X);
        double top = list.Min(value => value.Y);
        double right = list.Max(value => value.X + value.Width);
        double bottom = list.Max(value => value.Y + value.Height);
        return new(left, top, right - left, bottom - top);
    }
    private static double Distance((double X, double Y) first, (double X, double Y) second) =>
        Math.Sqrt(Math.Pow(first.X - second.X, 2) + Math.Pow(first.Y - second.Y, 2));
    private static double IntersectionOverUnion(BoundingRectangleInfo first, BoundingRectangleInfo second)
    {
        double left = Math.Max(first.X, second.X);
        double top = Math.Max(first.Y, second.Y);
        double right = Math.Min(first.X + first.Width, second.X + second.Width);
        double bottom = Math.Min(first.Y + first.Height, second.Y + second.Height);
        double intersection = Math.Max(0, right - left) * Math.Max(0, bottom - top);
        double union = first.Width * first.Height + second.Width * second.Height - intersection;
        return union <= 0 ? 0 : intersection / union;
    }
}
