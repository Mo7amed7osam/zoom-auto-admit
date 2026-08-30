using System.Drawing;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Screen;

public static class ScreenCropGeometry
{
    public static BoundingRectangleInfo GetParticipantRowCrop(
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel,
        BoundingRectangleInfo primaryScreen)
    {
        double left = Math.Max(primaryScreen.X, panel.PanelBounds.X);
        double top = Math.Max(primaryScreen.Y, row.RowBounds.Y - 16);
        double right = Math.Min(primaryScreen.X + primaryScreen.Width, panel.PanelBounds.X + panel.PanelBounds.Width);
        double bottom = Math.Min(primaryScreen.Y + primaryScreen.Height, row.RowBounds.Y + row.RowBounds.Height + 16);
        return new(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
    }

    public static Rectangle ToBitmapRectangle(
        BoundingRectangleInfo absoluteCrop,
        BoundingRectangleInfo primaryScreen)
    {
        int x = checked((int)Math.Floor(absoluteCrop.X - primaryScreen.X));
        int y = checked((int)Math.Floor(absoluteCrop.Y - primaryScreen.Y));
        int width = checked((int)Math.Ceiling(absoluteCrop.Width));
        int height = checked((int)Math.Ceiling(absoluteCrop.Height));
        return new Rectangle(x, y, width, height);
    }

    public static BoundingRectangleInfo ToAbsolute(
        BoundingRectangleInfo cropLocal,
        BoundingRectangleInfo absoluteCrop) =>
        new(
            absoluteCrop.X + cropLocal.X,
            absoluteCrop.Y + cropLocal.Y,
            cropLocal.Width,
            cropLocal.Height);

    public static BoundingRectangleInfo GetParticipantActionAreaCrop(
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel,
        BoundingRectangleInfo primaryScreen)
    {
        // Live Zoom evidence shows that a long name is truncated when Admit
        // appears, so the button may start left of the pre-hover text's right
        // edge. Limit OCR to the row's trusted right-side action band while
        // retaining that reflow area.
        double halfRow = row.RowBounds.X + row.RowBounds.Width * 0.50;
        double cappedTextEnd = Math.Min(
            row.TextBounds.X + row.TextBounds.Width + 6,
            row.RowBounds.X + row.RowBounds.Width * 0.58);
        double left = Math.Max(panel.PanelBounds.X, Math.Max(halfRow, cappedTextEnd));
        double top = Math.Max(primaryScreen.Y, row.RowBounds.Y - 12);
        double right = Math.Min(
            primaryScreen.X + primaryScreen.Width,
            Math.Min(panel.PanelBounds.X + panel.PanelBounds.Width, row.RowBounds.X + row.RowBounds.Width));
        double bottom = Math.Min(primaryScreen.Y + primaryScreen.Height, row.RowBounds.Y + row.RowBounds.Height + 12);
        return new(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
    }

    public static OcrResult MapScaledOcrToAbsolute(
        OcrResult scaledCropOcr,
        BoundingRectangleInfo absoluteCrop,
        double scale)
    {
        OcrWord MapWord(OcrWord word) => new(
            word.Text,
            new BoundingRectangleInfo(
                absoluteCrop.X + word.Bounds.X / scale,
                absoluteCrop.Y + word.Bounds.Y / scale,
                word.Bounds.Width / scale,
                word.Bounds.Height / scale));

        var lines = scaledCropOcr.Lines.Select(line =>
        {
            var words = line.Words.Select(MapWord).ToList();
            var bounds = new BoundingRectangleInfo(
                absoluteCrop.X + line.Bounds.X / scale,
                absoluteCrop.Y + line.Bounds.Y / scale,
                line.Bounds.Width / scale,
                line.Bounds.Height / scale);
            return new OcrLine(line.Text, bounds, words);
        }).ToList();
        return new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), absoluteCrop);
    }

    public static OcrResult MapMonitorOcrToVirtualDesktop(
        OcrResult localOcr,
        BoundingRectangleInfo monitorBounds)
    {
        OcrWord MapWord(OcrWord word) => new(
            word.Text,
            new BoundingRectangleInfo(
                monitorBounds.X + word.Bounds.X,
                monitorBounds.Y + word.Bounds.Y,
                word.Bounds.Width,
                word.Bounds.Height));

        var lines = localOcr.Lines.Select(line =>
        {
            var words = line.Words.Select(MapWord).ToList();
            var bounds = new BoundingRectangleInfo(
                monitorBounds.X + line.Bounds.X,
                monitorBounds.Y + line.Bounds.Y,
                line.Bounds.Width,
                line.Bounds.Height);
            return new OcrLine(line.Text, bounds, words);
        }).ToList();

        var allWords = lines.SelectMany(l => l.Words).ToList();
        return new OcrResult(lines, allWords, monitorBounds);
    }

    public static (BoundingRectangleInfo SourceMonitorBounds, string MonitorName, Rectangle LocalRect) GetMonitorLocalCropInfo(
        BoundingRectangleInfo absoluteCrop,
        IReadOnlyList<(string DeviceName, BoundingRectangleInfo Bounds)>? screens = null)
    {
        var monitorList = screens ?? System.Windows.Forms.Screen.AllScreens
            .Select(s => (s.DeviceName, new BoundingRectangleInfo(s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height)))
            .ToList();

        var cropCenter = (X: absoluteCrop.X + absoluteCrop.Width / 2.0, Y: absoluteCrop.Y + absoluteCrop.Height / 2.0);
        var matches = monitorList.Where(m => m.Bounds.Contains(cropCenter.X, cropCenter.Y)).ToList();
        if (matches.Count == 0)
        {
            matches = monitorList.Where(m =>
                m.Bounds.X <= absoluteCrop.X + absoluteCrop.Width && m.Bounds.X + m.Bounds.Width >= absoluteCrop.X &&
                m.Bounds.Y <= absoluteCrop.Y + absoluteCrop.Height && m.Bounds.Y + m.Bounds.Height >= absoluteCrop.Y).ToList();
        }
        var target = matches.Count > 0 ? matches[0] : monitorList[0];

        var monitorBounds = target.Bounds.Width > 0 ? target.Bounds : new BoundingRectangleInfo(0, 0, 1920, 1080);
        string deviceName = string.IsNullOrEmpty(target.DeviceName) ? @"\\.\DISPLAY1" : target.DeviceName;

        int localX = checked((int)Math.Floor(absoluteCrop.X - monitorBounds.X));
        int localY = checked((int)Math.Floor(absoluteCrop.Y - monitorBounds.Y));
        int width = checked(Math.Max(1, (int)Math.Ceiling(absoluteCrop.Width)));
        int height = checked(Math.Max(1, (int)Math.Ceiling(absoluteCrop.Height)));

        var localRect = new Rectangle(localX, localY, width, height);
        return (monitorBounds, deviceName, localRect);
    }
}
