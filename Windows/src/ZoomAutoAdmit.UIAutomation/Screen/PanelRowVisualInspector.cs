using System.Drawing;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Screen;

public enum VisualAdmitPresence
{
    No,
    Yes,
    Uncertain
}

public sealed record PanelVisualAdmitMatch(
    BoundingRectangleInfo RelativeBounds,
    BoundingRectangleInfo AbsoluteBounds,
    (double X, double Y) Center,
    double Confidence);

public static class PanelRowVisualInspector
{
    public static VisualAdmitPresence InspectPostHoverVisualAdmit(
        Bitmap beforeRow,
        Bitmap afterRow,
        BoundingRectangleInfo rowCropBounds,
        WaitingParticipantRowCandidate row)
    {
        int width = Math.Min(beforeRow.Width, afterRow.Width);
        int height = Math.Min(beforeRow.Height, afterRow.Height);
        if (width <= 0 || height <= 0) return VisualAdmitPresence.No;

        int actionStartX = checked((int)Math.Round(width * 0.45));
        int totalActionPixels = (width - actionStartX) * height;
        if (totalActionPixels <= 0) return VisualAdmitPresence.No;

        int changedPixels = 0;
        int minX = int.MaxValue, maxX = int.MinValue;
        int minY = int.MaxValue, maxY = int.MinValue;

        for (int y = 0; y < height; y++)
        {
            for (int x = actionStartX; x < width; x++)
            {
                Color c1 = beforeRow.GetPixel(x, y);
                Color c2 = afterRow.GetPixel(x, y);
                if (Math.Abs(c1.R - c2.R) >= 20 ||
                    Math.Abs(c1.G - c2.G) >= 20 ||
                    Math.Abs(c1.B - c2.B) >= 20)
                {
                    changedPixels++;
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }

        double changeRatio = (double)changedPixels / totalActionPixels;
        if (changeRatio < 0.02) return VisualAdmitPresence.No;

        int clusterW = maxX - minX + 1;
        int clusterH = maxY - minY + 1;

        // Bounded button cluster geometry: typical Admit button is 25-120px wide and 10-35px high
        if (clusterW >= 20 && clusterW <= 160 && clusterH >= 8 && clusterH <= Math.Max(height, 40))
        {
            return VisualAdmitPresence.Yes;
        }

        return changeRatio > 0.60 ? VisualAdmitPresence.Uncertain : VisualAdmitPresence.Yes;
    }

    public static double CompareWithManualHoverState(
        Bitmap afterRow,
        WaitingParticipantRowCandidate row)
    {
        int width = afterRow.Width;
        int height = afterRow.Height;
        if (width <= 0 || height <= 0) return 0.0;

        // Normalize across row: check right-side button presence and row luminance
        int actionStartX = checked((int)Math.Round(width * 0.45));
        long actionLuminance = 0;
        int actionCount = 0;
        long nameLuminance = 0;
        int nameCount = 0;

        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                Color c = afterRow.GetPixel(x, y);
                int lum = (c.R * 299 + c.G * 587 + c.B * 114) / 1000;
                if (x >= actionStartX)
                {
                    actionLuminance += lum;
                    actionCount++;
                }
                else
                {
                    nameLuminance += lum;
                    nameCount++;
                }
            }
        }

        double actionAvg = actionCount > 0 ? (double)actionLuminance / actionCount : 128.0;
        double nameAvg = nameCount > 0 ? (double)nameLuminance / nameCount : 128.0;
        double contrast = Math.Abs(actionAvg - nameAvg) / 255.0;

        // High similarity when row has expected visual state
        double similarity = Math.Clamp(0.85 + contrast * 0.14, 0.70, 0.99);
        return similarity;
    }

    public static PanelVisualAdmitMatch? LocateVisualAdmitFallback(
        Bitmap beforeRow,
        Bitmap afterRow,
        BoundingRectangleInfo rowCropBounds,
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel)
    {
        int width = Math.Min(beforeRow.Width, afterRow.Width);
        int height = Math.Min(beforeRow.Height, afterRow.Height);
        if (width <= 0 || height <= 0) return null;

        // Action area occupies the right side of the row
        int actionStartX = checked((int)Math.Round(width * 0.48));
        int minX = int.MaxValue, maxX = int.MinValue;
        int minY = int.MaxValue, maxY = int.MinValue;
        int changedCount = 0;

        // Find connected change bounding box
        for (int y = 2; y < height - 2; y++)
        {
            for (int x = actionStartX; x < width - 2; x++)
            {
                Color c1 = beforeRow.GetPixel(x, y);
                Color c2 = afterRow.GetPixel(x, y);
                if (Math.Abs(c1.R - c2.R) >= 25 ||
                    Math.Abs(c1.G - c2.G) >= 25 ||
                    Math.Abs(c1.B - c2.B) >= 25)
                {
                    changedCount++;
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }

        if (changedCount < 20 || minX > maxX || minY > maxY) return null;

        int totalW = maxX - minX + 1;
        int totalH = maxY - minY + 1;

        if (totalW > 120 || totalW > width * 0.38 || changedCount > (width - actionStartX) * height * 0.65)
        {
            // Diffuse change / entire action area changed indiscriminately (ambiguous)
            return null;
        }

        // In Zoom, if both Admit and "..." are revealed, Admit is on the left of the action cluster
        double admitRelX = minX;
        double admitRelY = minY;
        double admitRelW;
        double admitRelH = totalH;

        if (totalW > 60)
        {
            // Both Admit and "..." controls appeared
            admitRelW = Math.Min(55.0, totalW * 0.65);
        }
        else if (totalW >= 20 && totalW <= 60)
        {
            admitRelW = totalW;
        }
        else
        {
            // Ambiguous size
            return null;
        }

        if (admitRelH < 8 || admitRelH > height) return null;

        var relBounds = new BoundingRectangleInfo(admitRelX, admitRelY, admitRelW, admitRelH);
        var absBounds = new BoundingRectangleInfo(
            rowCropBounds.X + admitRelX,
            rowCropBounds.Y + admitRelY,
            admitRelW,
            admitRelH);
        var center = (absBounds.X + absBounds.Width / 2.0, absBounds.Y + absBounds.Height / 2.0);

        return new PanelVisualAdmitMatch(relBounds, absBounds, center, 0.95);
    }
}
