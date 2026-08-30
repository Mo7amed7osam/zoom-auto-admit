using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

public class ScreenCropGeometryTests
{
    [Fact]
    public void CropLocalCoordinatesMapBackToAbsolutePrimaryScreenCoordinates()
    {
        var absoluteCrop = new BoundingRectangleInfo(1480, 220, 440, 60);
        var localWord = new BoundingRectangleInfo(270, 20, 37, 10);

        Assert.Equal(new BoundingRectangleInfo(1750, 240, 37, 10),
            ScreenCropGeometry.ToAbsolute(localWord, absoluteCrop));
    }

    [Fact]
    public void RowCropIsClampedInsidePrimaryScreenAndPanel()
    {
        var row = new WaitingParticipantRowCandidate { RowBounds = new(1485, 230, 425, 24) };
        var panel = new ParticipantsPanelDetectionResult { PanelBounds = new(1480, 90, 440, 500) };
        var primary = new BoundingRectangleInfo(0, 0, 1920, 1080);

        var crop = ScreenCropGeometry.GetParticipantRowCrop(row, panel, primary);
        var bitmap = ScreenCropGeometry.ToBitmapRectangle(crop, primary);

        Assert.Equal(1480, bitmap.X);
        Assert.True(bitmap.Right <= 1920);
        Assert.True(bitmap.Height > row.RowBounds.Height);
    }

    [Fact]
    public void ActionAreaStartsAfterNameAndStaysInsideTrustedRowAndPanel()
    {
        var row = new WaitingParticipantRowCandidate
        {
            TextBounds = new(1510, 240, 120, 14),
            RowBounds = new(1485, 235, 425, 24)
        };
        var panel = new ParticipantsPanelDetectionResult { PanelBounds = new(1480, 90, 440, 500) };

        var crop = ScreenCropGeometry.GetParticipantActionAreaCrop(row, panel, new(0, 0, 1920, 1080));

        Assert.Equal(1697.5, crop.X);
        Assert.True(crop.X + crop.Width <= row.RowBounds.X + row.RowBounds.Width);
        Assert.True(crop.Y < row.RowBounds.Y);
        Assert.True(crop.Y + crop.Height > row.RowBounds.Y + row.RowBounds.Height);
    }

    [Fact]
    public void LongPreHoverNameDoesNotExcludeReflowedAdmitAreaFromCrop()
    {
        var row = new WaitingParticipantRowCandidate
        {
            TextBounds = new(1510, 240, 310, 14),
            RowBounds = new(1485, 235, 425, 24),
            SafeHoverPoint = (1564, 247)
        };
        var panel = new ParticipantsPanelDetectionResult { PanelBounds = new(1480, 90, 440, 500) };

        var crop = ScreenCropGeometry.GetParticipantActionAreaCrop(row, panel, new(0, 0, 1920, 1080));

        double simulatedReflowedAdmitX = row.RowBounds.X + row.RowBounds.Width * 0.72;
        Assert.True(simulatedReflowedAdmitX < row.TextBounds.X + row.TextBounds.Width);
        Assert.True(crop.X <= simulatedReflowedAdmitX);
        Assert.True(crop.X + crop.Width >= simulatedReflowedAdmitX + 45);
    }

    [Fact]
    public void ScaledOcrCoordinatesMapBackToAbsoluteScreenCoordinates()
    {
        var scaledWord = new OcrWord("Admit", new(240, 30, 111, 30));
        var scaled = new OcrResult(
            [new OcrLine("Admit", scaledWord.Bounds, [scaledWord])],
            [scaledWord],
            new(0, 0, 900, 180));

        var absolute = ScreenCropGeometry.MapScaledOcrToAbsolute(
            scaled,
            new BoundingRectangleInfo(1636, 228, 274, 48),
            3);

        var admit = Assert.Single(absolute.Words);
        Assert.Equal(new BoundingRectangleInfo(1716, 238, 37, 10), admit.Bounds);
    }

    [Fact]
    public void InMeetingToastMissingAdmitWithWaitingPhraseAndViewProducesLocalActionCrop()
    {
        var header1 = Line("eyouth Coordinator entered the", 1602, 924, 220, 12,
            ("eyouth", 1602, 45), ("Coordinator", 1652, 75), ("entered", 1732, 45), ("the", 1782, 24));
        var header2 = Line("waiting room", 1602, 944, 90, 12,
            ("waiting", 1602, 50), ("room", 1657, 35));
        var view = Line("View", 1790, 984, 29, 10, ("View", 1790, 29));
        var ocr = Ocr(header1, header2, view);

        Assert.True(InMeetingToastOcrRecoveryGeometry.ShouldAttempt(ocr));
        Assert.True(InMeetingToastOcrRecoveryGeometry.TryGetActionRowCrop(
            ocr, new(0, 0, 1920, 1080), out var crop));
        Assert.True(crop.X <= 1617);
        Assert.True(crop.X + crop.Width >= 1819);
        Assert.True(crop.Y <= 984);
        Assert.True(crop.Y + crop.Height >= 994);
    }

    [Fact]
    public void InMeetingToastRecoveryDoesNotRunWhenExactAdmitAlreadyExists()
    {
        var header = Line("entered the waiting room", 1602, 924, 180, 12,
            ("entered", 1602, 45), ("the", 1652, 24), ("waiting", 1681, 50), ("room", 1736, 35));
        var actions = Line("Admit View", 1617, 984, 202, 10,
            ("Admit", 1617, 37), ("View", 1790, 29));

        Assert.False(InMeetingToastOcrRecoveryGeometry.ShouldAttempt(Ocr(header, actions)));
    }

    [Fact]
    public void RecoveredToastAdmitUsesExistingThreeFrameGateAndExactlyOneClick()
    {
        var entered = Line("eyouth Coordinator entered the", 1618, 917, 231, 16,
            ("eyouth", 1618, 51), ("Coordinator", 1672, 89), ("entered", 1765, 56), ("the", 1826, 23));
        var waiting = Line("waiting room", 1618, 939, 97, 16,
            ("waiting", 1618, 52), ("room", 1676, 39));
        var fullView = Line("View", 1790, 984, 29, 10, ("View", 1790, 29));
        var full = Ocr(entered, waiting, fullView);
        var admit = new OcrWord("Admit", new(1617, 984, 37, 10));
        var duplicateView = new OcrWord("View", new(1791, 984, 29, 10));
        var crop = new OcrResult(
            [new OcrLine("Admit View", new(1617, 984, 203, 10), [admit, duplicateView])],
            [admit, duplicateView],
            new(1530, 968, 301, 42));

        var merged = OcrResultMerger.MergeWithoutOverlappingDuplicates(full, crop);
        var detection = WaitingRoomToastDetector.Detect(merged);
        var candidate = Assert.Single(detection.AllCandidates.Where(item => item.IsAccepted));
        Assert.Single(merged.Words.Where(word => word.Text.Equals("View", StringComparison.OrdinalIgnoreCase)));
        Assert.Equal(admit.Bounds, candidate.AdmitBounds);

        var gate = new AdmitOnceSafetyGate();
        var start = DateTimeOffset.UtcNow;
        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted,
            gate.ObserveConfirmationFrame([candidate], full.ImageBounds, start).Kind);
        Assert.Equal(AdmitOnceDecisionKind.Armed,
            gate.ObserveConfirmationFrame([candidate], full.ImageBounds, start.AddMilliseconds(150)).Kind);
        Assert.Equal(AdmitOnceDecisionKind.ClickReady,
            gate.ValidateFinalFrame([candidate], full.ImageBounds, start.AddMilliseconds(300), true).Kind);

        var mouse = new CountingMouseInput();
        var click = new SingleClickExecutor(mouse);
        Assert.True(click.TryClick((int)candidate.AdmitCenter.X, (int)candidate.AdmitCenter.Y));
        Assert.False(click.TryClick((int)candidate.AdmitCenter.X, (int)candidate.AdmitCenter.Y));
        Assert.Equal(1, mouse.ClickCount);
    }

    [Fact]
    public void PixelDifferenceConfirmsMeaningfulHoverVisualChange()
    {
        using var before = new System.Drawing.Bitmap(20, 20);
        using var after = new System.Drawing.Bitmap(20, 20);
        using (var graphics = System.Drawing.Graphics.FromImage(after))
            graphics.FillRectangle(System.Drawing.Brushes.White, 0, 0, 4, 4);

        double difference = RowVisualDifference.CalculatePercentage(before, after);

        Assert.Equal(4.0, difference, 3);
        Assert.True(HoverActivationPolicy.IsActivated(difference));
    }

    private static OcrLine Line(
        string text,
        double x,
        double y,
        double width,
        double height,
        params (string Text, double X, double Width)[] tokens)
    {
        var words = tokens.Select(token => new OcrWord(token.Text, new(token.X, y, token.Width, height))).ToList();
        return new OcrLine(text, new(x, y, width, height), words);
    }

    private static OcrResult Ocr(params OcrLine[] lines) =>
        new(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080));

    private sealed class CountingMouseInput : IMouseInput
    {
        public int ClickCount { get; private set; }
        public void LeftClickOncePreservingCursor(int x, int y) => ClickCount++;
        public void ScrollWheelPreservingCursor(int x, int y, int wheelDelta) { }
    }
}
