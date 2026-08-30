using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class MultiPersonWaitingNotificationTests
{
    [Theory]
    [InlineData(2)]
    [InlineData(5)]
    public void Detect_ExactMultiPersonPhraseAndLocalView(int count)
    {
        var ocr = Notification(count);

        var candidate = Assert.Single(
            MultiPersonWaitingNotificationDetector.Detect(ocr).AllCandidates.Where(item => item.IsAccepted));

        Assert.Equal(count, candidate.WaitingCount);
        Assert.Equal("View", candidate.ViewWord!.Text);
        Assert.Equal(0.99, candidate.Confidence, 2);
    }

    [Fact]
    public void Detect_UnrelatedViewsElsewhere_DoNotInterfere()
    {
        var source = Notification(2);
        var noise = new[]
        {
            new OcrWord("View", new BoundingRectangleInfo(100, 100, 30, 12)),
            new OcrWord("View", new BoundingRectangleInfo(500, 500, 30, 12))
        };
        var lines = source.Lines.Concat(noise.Select(word => new OcrLine("View", word.Bounds, [word]))).ToList();
        var ocr = new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), source.ImageBounds);

        var result = MultiPersonWaitingNotificationDetector.Detect(ocr);

        Assert.Single(result.AllCandidates.Where(candidate => candidate.IsAccepted));
        Assert.Equal(3, result.AllCandidates.Count);
    }

    [Fact]
    public void ThreeFrameGate_UsesFreshDynamicViewAndRejectsStaleCoordinates()
    {
        var candidate = Assert.Single(MultiPersonWaitingNotificationDetector.Detect(Notification(2)).AllCandidates.Where(item => item.IsAccepted));
        var gate = new MultiPersonNotificationSafetyGate();
        var now = DateTimeOffset.UtcNow;
        var primary = new BoundingRectangleInfo(0, 0, 1920, 1080);

        Assert.Equal(MultiPersonNotificationDecisionKind.FirstFrameAccepted, gate.Observe(candidate, primary, now).Kind);
        Assert.Equal(MultiPersonNotificationDecisionKind.Armed, gate.Observe(candidate, primary, now.AddMilliseconds(200)).Kind);
        Assert.Equal(MultiPersonNotificationDecisionKind.ClickReady,
            gate.ValidateFinal(candidate, primary, now.AddMilliseconds(400), interactiveDesktop: true).Kind);

        var moved = new MultiPersonWaitingNotificationCandidate
        {
            WaitingCount = 2,
            HeaderLine = candidate.HeaderLine,
            ViewWord = new("View", new(candidate.ViewWord!.Bounds.X + 100, candidate.ViewWord.Bounds.Y, 29, 10)),
            ViewCenter = (candidate.ViewCenter.X + 100, candidate.ViewCenter.Y),
            NotificationBounds = new(candidate.NotificationBounds.X + 100, candidate.NotificationBounds.Y, candidate.NotificationBounds.Width, candidate.NotificationBounds.Height),
            Confidence = 0.99,
            IsAccepted = true
        };
        Assert.Null(MultiPersonWaitingNotificationDetector.FindSame(candidate, [moved]));
    }

    [Fact]
    public void BrowserOwnedMultiPersonScreenshot_IsRejectedButZoomSurfaceIsAllowed()
    {
        Assert.False(NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.MultiPersonNotification, "chrome", "class", "title").IsAllowed);
        Assert.True(NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.MultiPersonNotification, "Zoom", "class", "title").IsAllowed);
    }

    [Fact]
    public void SameMultiNotificationIsSuppressedButLaterBatchIsEligible()
    {
        var candidate = Assert.Single(MultiPersonWaitingNotificationDetector.Detect(Notification(2)).AllCandidates.Where(item => item.IsAccepted));
        var cache = new HandledMultiNotificationCache(TimeSpan.FromSeconds(20));
        var now = DateTimeOffset.UtcNow;
        cache.MarkHandled(candidate, now);

        Assert.True(cache.IsSuppressed(candidate, now.AddSeconds(5)));
        Assert.False(cache.IsSuppressed(candidate, now.AddSeconds(21)));
    }

    [Fact]
    public void SuccessfulViewTransitionAllowsEquivalentFutureBatchImmediately()
    {
        var candidate = Assert.Single(MultiPersonWaitingNotificationDetector.Detect(Notification(2)).AllCandidates.Where(item => item.IsAccepted));
        var cache = new HandledMultiNotificationCache();
        var now = DateTimeOffset.UtcNow;
        cache.MarkHandled(candidate, now);

        cache.ObserveSuccessfulTransition(candidate, Array.Empty<MultiPersonWaitingNotificationCandidate>());

        Assert.False(cache.IsSuppressed(candidate, now.AddSeconds(1)));
    }

    private static OcrResult Notification(int count)
    {
        var headerWords = new[]
        {
            new OcrWord(count.ToString(), new(1500, 900, 14, 14)),
            new OcrWord("people", new(1520, 900, 45, 14)),
            new OcrWord("entered", new(1570, 900, 50, 14)),
            new OcrWord("the", new(1625, 900, 22, 14)),
            new OcrWord("waiting", new(1652, 900, 48, 14)),
            new OcrWord("room", new(1705, 900, 35, 14))
        };
        var header = new OcrLine($"{count} people entered the waiting room", new(1500, 900, 240, 14), headerWords);
        var view = new OcrWord("View", new(1700, 970, 29, 10));
        var viewLine = new OcrLine("View", view.Bounds, [view]);
        return new OcrResult([header, viewLine], headerWords.Append(view).ToList(), new(0, 0, 1920, 1080));
    }
}
