using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Screen;

public static class InMeetingToastOcrRecoveryGeometry
{
    public static bool ShouldAttempt(OcrResult ocr) =>
        !HasExactWord(ocr, "Admit") &&
        HasExactWord(ocr, "View") &&
        HasEnteredWaitingRoomPhrase(ocr);

    public static bool TryGetActionRowCrop(
        OcrResult ocr,
        BoundingRectangleInfo primaryScreen,
        out BoundingRectangleInfo crop)
    {
        crop = BoundingRectangleInfo.Empty;
        if (!ShouldAttempt(ocr)) return false;

        foreach (var view in ocr.Words
                     .Where(word => word.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase))
                     .OrderByDescending(word => word.Bounds.Y))
        {
            var localHeaderLines = ocr.Lines.Where(line =>
                    line.Bounds.Y <= view.Bounds.Y &&
                    view.Bounds.Y - (line.Bounds.Y + line.Bounds.Height) <= 180 &&
                    line.Bounds.X <= view.Bounds.X + view.Bounds.Width &&
                    line.Bounds.X + line.Bounds.Width >= view.Bounds.X - 320)
                .ToList();
            string localText = string.Join(" ", localHeaderLines.Select(line => line.Text));
            if (!localText.Contains("entered", StringComparison.OrdinalIgnoreCase) ||
                !Regex.IsMatch(localText, @"waiting\s+room", RegexOptions.IgnoreCase))
                continue;

            double trustedLeft = localHeaderLines.Min(line => line.Bounds.X) - 12;
            double left = Math.Max(primaryScreen.X, Math.Min(trustedLeft, view.Bounds.X - 260));
            double top = Math.Max(primaryScreen.Y, view.Bounds.Y - 16);
            double right = Math.Min(primaryScreen.X + primaryScreen.Width, view.Bounds.X + view.Bounds.Width + 12);
            double bottom = Math.Min(primaryScreen.Y + primaryScreen.Height, view.Bounds.Y + view.Bounds.Height + 16);
            if (right <= left || bottom <= top) continue;

            crop = new BoundingRectangleInfo(left, top, right - left, bottom - top);
            return true;
        }

        return false;
    }

    private static bool HasExactWord(OcrResult ocr, string expected) =>
        ocr.Words.Any(word => word.Text.Trim().Equals(expected, StringComparison.OrdinalIgnoreCase));

    private static bool HasEnteredWaitingRoomPhrase(OcrResult ocr)
    {
        string text = string.Join(" ", ocr.Lines.Select(line => line.Text));
        return text.Contains("entered", StringComparison.OrdinalIgnoreCase) &&
               Regex.IsMatch(text, @"waiting\s+room", RegexOptions.IgnoreCase);
    }
}
