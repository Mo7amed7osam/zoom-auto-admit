using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public static class MultiPersonWaitingNotificationDetector
{
    private static readonly Regex PhrasePattern = new(
        @"^(?<count>\d+)\s+(?:people|persons?)\s+(?:have\s+)?entered\s+the\s+waiting\s+room$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static MultiPersonWaitingDetectionResult Detect(OcrResult ocr)
    {
        var candidates = new List<MultiPersonWaitingNotificationCandidate>();
        foreach (var view in ocr.Words.Where(word => Clean(word.Text).Equals("View", StringComparison.OrdinalIgnoreCase)))
        {
            candidates.Add(Evaluate(view, ocr));
        }
        return new MultiPersonWaitingDetectionResult { AllCandidates = candidates };
    }

    public static MultiPersonWaitingNotificationCandidate? FindSame(
        MultiPersonWaitingNotificationCandidate expected,
        IEnumerable<MultiPersonWaitingNotificationCandidate> candidates) =>
        candidates
            .Where(candidate => candidate.IsAccepted &&
                                candidate.Confidence >= AdmitOnceSafetyGate.HighConfidence &&
                                candidate.WaitingCount == expected.WaitingCount)
            .OrderBy(candidate => Distance(candidate.ViewCenter, expected.ViewCenter))
            .FirstOrDefault(candidate =>
                Distance(candidate.ViewCenter, expected.ViewCenter) <= AdmitOnceSafetyGate.CenterMovementTolerance &&
                IntersectionOverUnion(candidate.NotificationBounds, expected.NotificationBounds) >= AdmitOnceSafetyGate.MinimumToastOverlap);

    private static MultiPersonWaitingNotificationCandidate Evaluate(OcrWord view, OcrResult ocr)
    {
        var reasons = new List<string>();
        var lines = ocr.Lines
            .Where(line =>
                line.Bounds.Y + line.Bounds.Height <= view.Bounds.Y + 5 &&
                view.Bounds.Y - (line.Bounds.Y + line.Bounds.Height) <= 180 &&
                line.Bounds.X + line.Bounds.Width >= view.Bounds.X - 350 &&
                line.Bounds.X <= view.Bounds.X + view.Bounds.Width + 100 &&
                !line.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase))
            .OrderBy(line => line.Bounds.Y)
            .ToList();

        var possibilities = lines.Select(line => (IReadOnlyList<OcrLine>)[line]).ToList();
        for (int first = 0; first < lines.Count; first++)
        {
            for (int second = first + 1; second < lines.Count; second++)
            {
                double gap = lines[second].Bounds.Y - (lines[first].Bounds.Y + lines[first].Bounds.Height);
                if (gap >= -5 && gap <= 35 && Math.Abs(lines[first].Bounds.X - lines[second].Bounds.X) <= 140)
                    possibilities.Add([lines[first], lines[second]]);
            }
        }

        foreach (var source in possibilities.OrderByDescending(item => item.Count))
        {
            string text = Normalize(string.Join(" ", source.OrderBy(line => line.Bounds.Y).Select(line => line.Text)));
            var match = PhrasePattern.Match(text);
            if (!match.Success || !int.TryParse(match.Groups["count"].Value, out int count) || count < 2) continue;

            var headerBounds = Union(source.Select(line => line.Bounds));
            double overlap = HorizontalOverlap(headerBounds, view.Bounds);
            if (overlap < 5 && Math.Abs((headerBounds.X + headerBounds.Width) - view.Bounds.X) > 250) continue;

            var notificationBounds = UnionWithPadding(
                source.Select(line => line.Bounds).Append(view.Bounds),
                ocr.ImageBounds);
            reasons.Add($"Exact multi-person Waiting Room phrase with count {count}.");
            reasons.Add("Exact local View is spatially associated with the same notification.");
            return new MultiPersonWaitingNotificationCandidate
            {
                WaitingCount = count,
                HeaderLine = new OcrLine(text, headerBounds, source.SelectMany(line => line.Words).ToList()),
                ViewWord = view,
                NotificationBounds = notificationBounds,
                ViewCenter = view.Center,
                Confidence = 0.99,
                IsAccepted = true,
                DetectionReasons = reasons
            };
        }

        return new MultiPersonWaitingNotificationCandidate
        {
            ViewWord = view,
            ViewCenter = view.Center,
            Confidence = 0.20,
            IsAccepted = false,
            DetectionReasons = ["No exact local 'N people entered the waiting room' phrase was found above this View."]
        };
    }

    private static BoundingRectangleInfo UnionWithPadding(
        IEnumerable<BoundingRectangleInfo> bounds,
        BoundingRectangleInfo image)
    {
        var value = Union(bounds);
        double left = Math.Max(image.X, value.X - 15);
        double top = Math.Max(image.Y, value.Y - 15);
        double right = Math.Min(image.X + image.Width, value.X + value.Width + 20);
        double bottom = Math.Min(image.Y + image.Height, value.Y + value.Height + 15);
        return new(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
    }

    private static BoundingRectangleInfo Union(IEnumerable<BoundingRectangleInfo> values)
    {
        var list = values.ToList();
        double left = list.Min(value => value.X);
        double top = list.Min(value => value.Y);
        double right = list.Max(value => value.X + value.Width);
        double bottom = list.Max(value => value.Y + value.Height);
        return new(left, top, right - left, bottom - top);
    }

    private static double HorizontalOverlap(BoundingRectangleInfo first, BoundingRectangleInfo second) =>
        Math.Max(0, Math.Min(first.X + first.Width, second.X + second.Width) - Math.Max(first.X, second.X));
    private static string Clean(string value) => value.Trim(' ', '\t', '\r', '\n', '.', ',', ':', ';', '(', ')', '[', ']');
    private static string Normalize(string value) => Regex.Replace(value.Trim(), @"\s+", " ");
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
