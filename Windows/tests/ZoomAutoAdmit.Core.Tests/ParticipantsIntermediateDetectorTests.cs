using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class ParticipantsIntermediateDetectorTests
{
    [Fact]
    public void Detect_TapForParticipants_IsAcceptedAtHighConfidence()
    {
        var line = new OcrLine(
            "Tap for Participants",
            new BoundingRectangleInfo(800, 500, 200, 30),
            [
                new("Tap", new(800, 500, 40, 30)),
                new("for", new(845, 500, 30, 30)),
                new("Participants", new(880, 500, 120, 30))
            ]);
        var ocr = new OcrResult([line], line.Words, new(0, 0, 1920, 1080));

        var result = ParticipantsIntermediateDetector.Detect(ocr);

        Assert.True(result.IsAccepted);
        Assert.Equal(ParticipantsIntermediateKind.TapForParticipants, result.Kind);
        Assert.Equal(0.99, result.Confidence);
        Assert.Equal(900.0, result.ActionCenter.X, precision: 1);
        Assert.Equal(515.0, result.ActionCenter.Y, precision: 1);
    }

    [Fact]
    public void Detect_ToolbarParticipantsButton_WhenPanelClosed_IsAccepted()
    {
        var line = new OcrLine(
            "Participants (2)",
            new BoundingRectangleInfo(960, 1030, 100, 25),
            [new("Participants", new(960, 1030, 80, 25)), new("(2)", new(1045, 1030, 15, 25))]);
        var ocr = new OcrResult([line], line.Words, new(0, 0, 1920, 1080));

        var panel = new ParticipantsPanelDetectionResult { IsPanelVisible = false };
        var result = ParticipantsIntermediateDetector.Detect(ocr, panel);

        Assert.True(result.IsAccepted);
        Assert.Equal(ParticipantsIntermediateKind.ToolbarParticipantsButton, result.Kind);
        Assert.Equal(0.95, result.Confidence);
        Assert.Equal(1010.0, result.ActionCenter.X, precision: 1);
        Assert.Equal(1042.5, result.ActionCenter.Y, precision: 1);
    }

    [Fact]
    public void Detect_ToolbarParticipants_WhenPanelAlreadyOpen_IsIgnored()
    {
        var line = new OcrLine(
            "Participants (2)",
            new BoundingRectangleInfo(1500, 120, 150, 25),
            [new("Participants", new(1500, 120, 120, 25)), new("(2)", new(1625, 120, 25, 25))]);
        var ocr = new OcrResult([line], line.Words, new(0, 0, 1920, 1080));

        var panel = new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            PanelBounds = new(1480, 100, 400, 600)
        };
        var result = ParticipantsIntermediateDetector.Detect(ocr, panel);

        Assert.False(result.IsAccepted);
        Assert.Equal(ParticipantsIntermediateKind.None, result.Kind);
    }

    [Fact]
    public void Detect_CodeNoise_IsRejected()
    {
        var line = new OcrLine(
            "public class Participants : IDisposable",
            new BoundingRectangleInfo(200, 200, 300, 20),
            []);
        var ocr = new OcrResult([line], [], new(0, 0, 1920, 1080));

        var result = ParticipantsIntermediateDetector.Detect(ocr);

        Assert.False(result.IsAccepted);
        Assert.Equal(ParticipantsIntermediateKind.None, result.Kind);
    }

    [Fact]
    public void NotificationSurfacePolicy_RejectsParticipantsInBrowser()
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            "chrome",
            "Chrome_WidgetWin_1",
            "Google Chrome",
            hasZoomParentOwnerChain: false);

        Assert.False(decision.IsAllowed);
    }

    [Fact]
    public void NotificationSurfacePolicy_AcceptsParticipantsInLiveZoom()
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            "Zoom",
            "ConfMultiTabContentWndClass",
            "Zoom Meeting",
            hasZoomParentOwnerChain: true);

        Assert.True(decision.IsAllowed);
    }
}
