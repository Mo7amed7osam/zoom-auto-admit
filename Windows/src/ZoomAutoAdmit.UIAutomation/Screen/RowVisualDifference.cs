using System.Drawing;

namespace ZoomAutoAdmit.UIAutomation.Screen;

public static class RowVisualDifference
{
    public static double CalculatePercentage(Bitmap before, Bitmap after, int channelThreshold = 18)
    {
        int width = Math.Min(before.Width, after.Width);
        int height = Math.Min(before.Height, after.Height);
        if (width <= 0 || height <= 0) return 0;
        long changed = 0;
        long total = (long)width * height;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                Color first = before.GetPixel(x, y);
                Color second = after.GetPixel(x, y);
                if (Math.Abs(first.R - second.R) >= channelThreshold ||
                    Math.Abs(first.G - second.G) >= channelThreshold ||
                    Math.Abs(first.B - second.B) >= channelThreshold)
                    changed++;
            }
        }
        return changed * 100.0 / total;
    }
}
