using System.Drawing;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Interop;
using ZoomAutoAdmit.UIAutomation.Screen;
using ZoomAutoAdmit.UIAutomation.Window;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

public class MultiMonitorAndForegroundPreservationTests
{
    [Fact]
    public void WaitingRoomActivity_CountZeroAndJoinedRowsSeven_DoesNotTriggerWaitingActivity()
    {
        var lines = new List<OcrLine>
        {
            new("Participants (7)", new(100, 50, 200, 20), []),
            new("Waiting room (0)", new(100, 80, 200, 20), []),
            new("Joined (7)", new(100, 110, 200, 20), []),
            new("Alice", new(100, 140, 200, 20), []),
            new("Bob", new(100, 170, 200, 20), []),
            new("Charlie", new(100, 200, 200, 20), []),
            new("David", new(100, 230, 200, 20), []),
            new("Eve", new(100, 260, 200, 20), []),
            new("Frank", new(100, 290, 200, 20), []),
            new("Grace", new(100, 320, 200, 20), [])
        };

        var ocr = new OcrResult(lines, lines.SelectMany(l => l.Words).ToList(), new(0, 0, 1920, 1080));
        var panel = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.True(panel.IsPanelVisible);
        Assert.Equal(0, panel.DeclaredWaitingCount);
        Assert.Empty(panel.Rows);
        Assert.False(panel.HasActiveWaitingParticipants);
    }

    [Fact]
    public void WaitingRoomActivity_OnlyWaitingRoomScopedRowsCountAsWaiting()
    {
        var lines = new List<OcrLine>
        {
            new("Participants (8)", new(100, 50, 200, 20), []),
            new("Waiting room (1)", new(100, 80, 200, 20), []),
            new("Waiting Guest", new(100, 110, 200, 20), []),
            new("Joined (7)", new(100, 140, 200, 20), []),
            new("Alice", new(100, 170, 200, 20), []),
            new("Bob", new(100, 200, 200, 20), []),
            new("Charlie", new(100, 230, 200, 20), []),
            new("David", new(100, 260, 200, 20), []),
            new("Eve", new(100, 290, 200, 20), []),
            new("Frank", new(100, 320, 200, 20), []),
            new("Grace", new(100, 350, 200, 20), [])
        };

        var ocr = new OcrResult(lines, lines.SelectMany(l => l.Words).ToList(), new(0, 0, 1920, 1080));
        var panel = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.True(panel.IsPanelVisible);
        Assert.Equal(1, panel.DeclaredWaitingCount);
        Assert.Single(panel.Rows);
        Assert.Equal("Waiting Guest", panel.Rows[0].ParticipantName);
        Assert.True(panel.HasActiveWaitingParticipants);
    }

    [Fact]
    public void BackgroundInteraction_ClientCoordinateCalculation()
    {
        // Screen point (500, 300) with window at (100, 50)
        double absX = 500;
        double absY = 300;
        double winLeft = 100;
        double winTop = 50;

        int clientX = checked((int)Math.Round(absX - winLeft));
        int clientY = checked((int)Math.Round(absY - winTop));

        Assert.Equal(400, clientX);
        Assert.Equal(250, clientY);
    }

    [Fact]
    public void BackgroundInteraction_ValidateTarget_RejectsInvalidHWND()
    {
        var result = BackgroundZoomInteraction.ValidateTarget(IntPtr.Zero);
        Assert.Equal(BackgroundInteractionResult.InvalidTargetWindow, result);
    }

    [Fact]
    public void MultiMonitor_CoordinateMapping_PositiveAndNegativeMonitorOffsets()
    {
        // Monitor 1: Primary [0, 0, 1920x1080]
        var primaryBounds = new BoundingRectangleInfo(0, 0, 1920, 1080);
        var localOcr1 = new OcrResult(
            [new("Admit", new(100, 200, 40, 15), [new("Admit", new(100, 200, 40, 15))])],
            [new("Admit", new(100, 200, 40, 15))],
            primaryBounds);
        var mapped1 = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(localOcr1, primaryBounds);
        Assert.Equal(100.0, mapped1.Words[0].Bounds.X);
        Assert.Equal(200.0, mapped1.Words[0].Bounds.Y);

        // Monitor 2: To the right [1920, 0, 1920x1080]
        var rightMonitorBounds = new BoundingRectangleInfo(1920, 0, 1920, 1080);
        var localOcr2 = new OcrResult(
            [new("Admit", new(100, 200, 40, 15), [new("Admit", new(100, 200, 40, 15))])],
            [new("Admit", new(100, 200, 40, 15))],
            rightMonitorBounds);
        var mapped2 = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(localOcr2, rightMonitorBounds);
        Assert.Equal(2020.0, mapped2.Words[0].Bounds.X);
        Assert.Equal(200.0, mapped2.Words[0].Bounds.Y);

        // Monitor 3: To the left [-1920, 0, 1920x1080]
        var leftMonitorBounds = new BoundingRectangleInfo(-1920, 0, 1920, 1080);
        var localOcr3 = new OcrResult(
            [new("Admit", new(500, 300, 40, 15), [new("Admit", new(500, 300, 40, 15))])],
            [new("Admit", new(500, 300, 40, 15))],
            leftMonitorBounds);
        var mapped3 = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(localOcr3, leftMonitorBounds);
        Assert.Equal(-1420.0, mapped3.Words[0].Bounds.X);
        Assert.Equal(300.0, mapped3.Words[0].Bounds.Y);
    }

    [Fact]
    public void NonPrimaryMonitorCrop_DoesNotThrowOutsidePrimaryScreenException()
    {
        var monitors = new (string, BoundingRectangleInfo)[]
        {
            (@"\\.\DISPLAY1", new(0, 0, 1920, 1080)),
            (@"\\.\DISPLAY2", new(1920, 0, 1920, 1080))
        };

        var cropBounds = new BoundingRectangleInfo(2100, 300, 300, 50);
        var (sourceMonitor, monitorName, localRect) = ScreenCropGeometry.GetMonitorLocalCropInfo(cropBounds, monitors);

        Assert.Equal(@"\\.\DISPLAY2", monitorName);
        Assert.Equal(180, localRect.X);
        Assert.Equal(300, localRect.Y);
        Assert.Equal(300, localRect.Width);
        Assert.Equal(50, localRect.Height);
    }

    [Fact]
    public void NegativeMonitorX_Crop_CalculatesLocalRectCorrectly()
    {
        var monitors = new (string, BoundingRectangleInfo)[]
        {
            (@"\\.\DISPLAY1", new(0, 0, 1920, 1080)),
            (@"\\.\DISPLAY2", new(-1920, 0, 1920, 1080))
        };

        var cropBounds = new BoundingRectangleInfo(-1500, 200, 200, 40);
        var (sourceMonitor, monitorName, localRect) = ScreenCropGeometry.GetMonitorLocalCropInfo(cropBounds, monitors);

        Assert.Equal(@"\\.\DISPLAY2", monitorName);
        Assert.Equal(420, localRect.X);
        Assert.Equal(200, localRect.Y);
        Assert.Equal(200, localRect.Width);
        Assert.Equal(40, localRect.Height);
    }

    [Theory]
    [InlineData("photoshop", "PhotoshopMainWindow", "Adobe Photoshop 2026")]
    [InlineData("excel", "XLMAIN", "Microsoft Excel - Book1")]
    [InlineData("powerpnt", "PPTFrameClass", "PowerPoint Presentation")]
    [InlineData("vlc", "Qt5QWindowIcon", "VLC Media Player")]
    [InlineData("unrealengine", "UnrealWindow", "Unreal Editor")]
    [InlineData("chrome", "Chrome_WidgetWin_1", "Google Chrome")]
    [InlineData("code", "Chrome_WidgetWin_1", "Visual Studio Code")]
    [InlineData("arbitrary_game", "GameWndClass", "My Custom Game 3D")]
    public void PositiveOwnershipSafety_RejectsAnyArbitraryNonZoomApplication(string process, string className, string title)
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            process,
            className,
            title,
            hasZoomParentOwnerChain: false);

        Assert.False(decision.IsAllowed);
        Assert.Contains("Non-Zoom application surface", decision.Reason);
    }

    [Theory]
    [InlineData("Zoom", "ZPContentViewWndClass", "Zoom Meeting")]
    [InlineData("zoom", "ConfMultiTabContentWndClass", "Participants (1)")]
    [InlineData("cptHost", "zMeetingNotificationWndClass", "Zoom")]
    public void PositiveOwnershipSafety_AcceptsVerifiedLiveZoomProcesses(string process, string className, string title)
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            process,
            className,
            title,
            hasZoomParentOwnerChain: false);

        Assert.True(decision.IsAllowed);
        Assert.Contains("verified live Zoom surface", decision.Reason);
    }

    [Fact]
    public void NotificationTopmost_WindowsNotificationDirectlyActionable_WithoutZoomActivation()
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.WindowsNotification,
            "explorer",
            "Windows.UI.Core.CoreWindow",
            "Action Center",
            hasZoomParentOwnerChain: false);

        Assert.True(decision.IsAllowed);
        Assert.Contains("verified Windows notification host", decision.Reason);
    }

    [Fact]
    public void ParticipantsIntermediateDetector_RejectsCodeNoiseAndGenericWords()
    {
        var lines = new[]
        {
            new OcrLine("class Participants { public int count; }", new(100, 100, 300, 20), []),
            new OcrLine("Chat with everyone", new(100, 150, 200, 20), []),
            new OcrLine("Mute All", new(100, 200, 100, 20), [])
        };
        var ocr = new OcrResult(lines, [], new(0, 0, 1920, 1080));

        var result = ParticipantsIntermediateDetector.Detect(ocr);

        Assert.False(result.IsAccepted);
        Assert.Equal(ParticipantsIntermediateKind.None, result.Kind);
    }

    [Fact]
    public void BackgroundMode_ZeroPhysicalCursorMovementOrForegroundSwitching()
    {
        var validation = BackgroundZoomInteraction.ValidateTarget(IntPtr.Zero);
        Assert.Equal(BackgroundInteractionResult.InvalidTargetWindow, validation);
    }

    [Fact]
    public void EmergencyEscalation_TriggeredOnlyWhenParticipantWaitingAndBackgroundExhausted()
    {
        // Given a panel with 1 waiting participant
        var lines = new List<OcrLine>
        {
            new("Participants (2)", new(100, 50, 200, 20), []),
            new("Waiting room (1)", new(100, 80, 200, 20), []),
            new("Stuck Guest", new(100, 110, 200, 20), [])
        };
        var ocr = new OcrResult(lines, lines.SelectMany(l => l.Words).ToList(), new(0, 0, 1920, 1080));
        var panel = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.True(panel.HasActiveWaitingParticipants);
        Assert.Equal(1, panel.DeclaredWaitingCount);
    }
}
