using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Ocr;

public static class OcrResultMerger
{
    public static OcrResult MergeWithoutOverlappingDuplicates(OcrResult full, OcrResult crop)
    {
        var words = full.Words.ToList();
        foreach (var word in crop.Words)
        {
            if (!words.Any(existing => SameItem(existing.Text, existing.Bounds, word.Text, word.Bounds, 6)))
                words.Add(word);
        }

        var lines = full.Lines.ToList();
        foreach (var line in crop.Lines)
        {
            if (!lines.Any(existing => SameItem(existing.Text, existing.Bounds, line.Text, line.Bounds, 8)))
                lines.Add(line);
        }
        return new OcrResult(lines, words, full.ImageBounds);
    }

    private static bool SameItem(
        string firstText,
        BoundingRectangleInfo first,
        string secondText,
        BoundingRectangleInfo second,
        double centerTolerance)
    {
        if (!Normalize(firstText).Equals(Normalize(secondText), StringComparison.OrdinalIgnoreCase)) return false;
        double firstCenterX = first.X + first.Width / 2.0;
        double firstCenterY = first.Y + first.Height / 2.0;
        double secondCenterX = second.X + second.Width / 2.0;
        double secondCenterY = second.Y + second.Height / 2.0;
        return Math.Abs(firstCenterX - secondCenterX) <= centerTolerance &&
               Math.Abs(firstCenterY - secondCenterY) <= centerTolerance;
    }

    private static string Normalize(string text) =>
        string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
