using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Ocr;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

public class ParticipantsPanelScrollRecoveryTests
{
    [Fact]
    public async Task ScrolledPanel_ScrollUpRecovery_RevealsWaitingHeaderAndAdmitAll()
    {
        var mouse = new FakeScrollMouseInput();
        var panelBounds = new BoundingRectangleInfo(1500, 100, 400, 600);

        // Frame 1 (scrolled down): Only Joined header and participants visible, no Waiting Room
        var frame1Ocr = new OcrResult(
            [
                new("Participants (10)", new(1520, 120, 150, 16), []),
                new("Joined (8)", new(1520, 160, 100, 16), []),
                new("Participant A", new(1520, 200, 120, 16), [])
            ],
            [],
            new(0, 0, 1920, 1080));

        // Frame 2 (after scroll): Waiting room (2) and Admit all become visible
        var frame2Ocr = new OcrResult(
            [
                new("Participants (10)", new(1520, 120, 150, 16), []),
                new("Waiting room (2)", new(1520, 160, 140, 16), []),
                new("Admit all", new(1800, 160, 60, 16), [new("Admit", new(1800, 160, 35, 16)), new("all", new(1840, 160, 20, 16))]),
                new("Participant 1", new(1520, 200, 120, 16), []),
                new("Participant 2", new(1520, 240, 120, 16), []),
                new("Joined (8)", new(1520, 280, 100, 16), [])
            ],
            [new("Admit", new(1800, 160, 35, 16)), new("all", new(1840, 160, 20, 16))],
            new(0, 0, 1920, 1080));

        int captures = 0;
        Task<AutoAdmitScan> FakeCapture(WindowsNativeOcrEngine engine, string path, CancellationToken token)
        {
            captures++;
            var ocr = captures <= 1 ? frame1Ocr : frame2Ocr;
            var detection = WaitingRoomToastDetector.Detect(ocr);
            var multi = MultiPersonWaitingNotificationDetector.Detect(ocr);
            return Task.FromResult(new AutoAdmitScan(detection, multi, ocr, new(0, 0, 1920, 1080), DateTimeOffset.UtcNow));
        }

        var result = await ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
            null!,
            mouse,
            panelBounds,
            "dummy.png",
            (x, y) => true,
            FakeCapture,
            CancellationToken.None);

        Assert.Equal(1, mouse.ScrollCount);
        Assert.True(mouse.LastDelta > 0); // Scrolled wheel up
        Assert.True(panelBounds.Contains(mouse.LastTarget.X, mouse.LastTarget.Y));

        var admitAll = PanelAdmitAllDetector.Detect(result.Ocr);
        Assert.True(admitAll.IsAccepted);
        Assert.Equal(2, admitAll.WaitingCount);
    }

    [Fact]
    public async Task ScrollTarget_AlwaysInsideLiveParticipantsPanel()
    {
        var mouse = new FakeScrollMouseInput();
        var panelBounds = new BoundingRectangleInfo(1400, 150, 450, 700);

        var emptyOcr = new OcrResult([], [], new(0, 0, 1920, 1080));
        Task<AutoAdmitScan> FakeCapture(WindowsNativeOcrEngine engine, string path, CancellationToken token)
        {
            return Task.FromResult(new AutoAdmitScan(new(), new(), emptyOcr, new(0, 0, 1920, 1080), DateTimeOffset.UtcNow));
        }

        await ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
            null!,
            mouse,
            panelBounds,
            "dummy.png",
            (x, y) => true,
            FakeCapture,
            CancellationToken.None);

        Assert.True(panelBounds.Contains(mouse.LastTarget.X, mouse.LastTarget.Y));
    }

    [Fact]
    public async Task ScrollRejected_WhenTargetBelongsToBrowserOrIDE()
    {
        var mouse = new FakeScrollMouseInput();
        var panelBounds = new BoundingRectangleInfo(100, 100, 500, 600);

        var emptyOcr = new OcrResult([], [], new(0, 0, 1920, 1080));
        Task<AutoAdmitScan> FakeCapture(WindowsNativeOcrEngine engine, string path, CancellationToken token)
        {
            return Task.FromResult(new AutoAdmitScan(new(), new(), emptyOcr, new(0, 0, 1920, 1080), DateTimeOffset.UtcNow));
        }

        // Live Zoom check returns false (e.g. Chrome / VS Code under point)
        await ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
            null!,
            mouse,
            panelBounds,
            "dummy.png",
            (x, y) => false,
            FakeCapture,
            CancellationToken.None);

        Assert.Equal(0, mouse.ScrollCount); // No scrolling attempted
    }

    [Fact]
    public async Task BoundedMaximumScrollAttempts_NoInfiniteLoop()
    {
        var mouse = new FakeScrollMouseInput();
        var panelBounds = new BoundingRectangleInfo(1500, 100, 400, 600);

        // Never reveals header
        var emptyOcr = new OcrResult(
            [new("Participants (5)", new(1520, 120, 150, 16), [])],
            [],
            new(0, 0, 1920, 1080));

        Task<AutoAdmitScan> FakeCapture(WindowsNativeOcrEngine engine, string path, CancellationToken token)
        {
            return Task.FromResult(new AutoAdmitScan(new(), new(), emptyOcr, new(0, 0, 1920, 1080), DateTimeOffset.UtcNow));
        }

        await ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
            null!,
            mouse,
            panelBounds,
            "dummy.png",
            (x, y) => true,
            FakeCapture,
            CancellationToken.None);

        Assert.Equal(ParticipantsPanelScrollRecovery.MaxScrollAttempts, mouse.ScrollCount);
    }

    [Fact]
    public void CountGreaterThanOrEqualTo2_SuppressesIndividualHover_AndChoosesBatchAdmitAll()
    {
        // When 2 waiting users and Admit all are visible, priority chooses PanelAdmitAll
        var admitAll = new PanelAdmitAllCandidate
        {
            IsAccepted = true,
            Confidence = 0.99,
            WaitingCount = 2,
            AdmitAllBounds = new(1800, 160, 60, 16),
            AdmitAllCenter = (1830, 168)
        };

        var panelRow = new WaitingParticipantRowCandidate
        {
            ParticipantName = "Mohab",
            RowBounds = new(1520, 200, 350, 24),
            SafeHoverPoint = (1580, 212),
            Confidence = 0.95
        };

        var choice = AutoAdmitPrioritySelector.Choose(
            eligibleToasts: [],
            multiPersonNotification: null,
            panelAdmitAll: admitAll,
            eligiblePanelRow: panelRow);

        Assert.Equal(AutoAdmitPathKind.PanelAdmitAll, choice);
    }

    [Fact]
    public void CountEquals1_ChoosesParticipantsPanelIndividualHover()
    {
        var panelRow = new WaitingParticipantRowCandidate
        {
            ParticipantName = "Mohab",
            RowBounds = new(1520, 200, 350, 24),
            SafeHoverPoint = (1580, 212),
            Confidence = 0.95
        };

        var choice = AutoAdmitPrioritySelector.Choose(
            eligibleToasts: [],
            multiPersonNotification: null,
            panelAdmitAll: null,
            eligiblePanelRow: panelRow);

        Assert.Equal(AutoAdmitPathKind.ParticipantsPanel, choice);
    }

    [Fact]
    public void ConsecutiveAdmissionCycles_AfterOneAdmitted_RemainingUserDetectedNextCycle()
    {
        // Cycle 1: Waiting room has 2 users: UserA and UserB
        var rowA = new WaitingParticipantRowCandidate { ParticipantName = "UserA", RowBounds = new(1520, 200, 350, 24) };
        var rowB = new WaitingParticipantRowCandidate { ParticipantName = "UserB", RowBounds = new(1520, 240, 350, 24) };
        var panel1 = new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            DeclaredWaitingCount = 2,
            Rows = [rowA, rowB]
        };

        // UserA is admitted.
        var cache = new HandledNotificationCache();
        cache.MarkParticipantHandled("UserA", DateTimeOffset.UtcNow);

        // Cycle 2: Fresh scan shows only UserB remaining
        var panel2 = new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            DeclaredWaitingCount = 1,
            Rows = [rowB]
        };

        var eligibleRows = panel2.Rows
            .Where(r => !cache.IsParticipantSuppressed(r.ParticipantName, DateTimeOffset.UtcNow))
            .ToList();

        var nextTarget = Assert.Single(eligibleRows);
        Assert.Equal("UserB", nextTarget.ParticipantName);
    }

    [Fact]
    public void ConsecutiveAdmissionCycles_AfterAdmitAll_NewIncomingUserDetectedNextCycle()
    {
        // Batch A+B handled
        var batchCache = new HandledBatchCache();
        var handledBatch = new PanelAdmitAllCandidate
        {
            IsAccepted = true,
            WaitingCount = 2,
            OriginalParticipants = ["UserA", "UserB"],
            AdmitAllBounds = new(1800, 160, 60, 16)
        };
        batchCache.MarkHandled(handledBatch, DateTimeOffset.UtcNow);

        // Cycle 2: New participant UserC enters
        var rowC = new WaitingParticipantRowCandidate { ParticipantName = "UserC", RowBounds = new(1520, 200, 350, 24) };
        var panel2 = new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            DeclaredWaitingCount = 1,
            Rows = [rowC]
        };

        var notificationCache = new HandledNotificationCache();
        var nextTarget = panel2.Rows
            .FirstOrDefault(r => !notificationCache.IsParticipantSuppressed(r.ParticipantName, DateTimeOffset.UtcNow));

        Assert.NotNull(nextTarget);
        Assert.Equal("UserC", nextTarget.ParticipantName);
    }

    [Fact]
    public void ViewTransition_IntermediateAction_ClickedExactlyOnce()
    {
        var mouse = new FakeScrollMouseInput();
        var executor = new SingleClickExecutor(mouse);

        var intermediate = new ParticipantsIntermediateCandidate
        {
            Kind = ParticipantsIntermediateKind.TapForParticipants,
            ActionBounds = new(800, 500, 200, 30),
            ActionCenter = (900, 515),
            IsAccepted = true
        };

        // First click succeeds
        bool first = executor.TryClick(checked((int)intermediate.ActionCenter.X), checked((int)intermediate.ActionCenter.Y));
        Assert.True(first);
        Assert.Equal(1, mouse.ClickCount);

        // Second click rejected by SingleClickExecutor
        bool second = executor.TryClick(checked((int)intermediate.ActionCenter.X), checked((int)intermediate.ActionCenter.Y));
        Assert.False(second);
        Assert.Equal(1, mouse.ClickCount);
    }

    [Fact]
    public void ViewTransition_DirectPanel_DoesNotTriggerIntermediateClick()
    {
        var panel = new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            ParticipantsHeader = new("Participants", new(1500, 100, 200, 25), []),
            WaitingRoomHeader = new("Waiting room (2)", new(1500, 140, 200, 25), [])
        };

        var verifier = new ViewPanelTransitionVerifier();
        Assert.True(verifier.IsVerified(panel));
    }

    private sealed class FakeScrollMouseInput : IMouseInput
    {
        public int ClickCount { get; private set; }
        public int ScrollCount { get; private set; }
        public (int X, int Y) LastTarget { get; private set; }
        public int LastDelta { get; private set; }

        public void LeftClickOncePreservingCursor(int x, int y)
        {
            ClickCount++;
            LastTarget = (x, y);
        }

        public void ScrollWheelPreservingCursor(int x, int y, int wheelDelta)
        {
            ScrollCount++;
            LastTarget = (x, y);
            LastDelta = wheelDelta;
        }
    }
}
