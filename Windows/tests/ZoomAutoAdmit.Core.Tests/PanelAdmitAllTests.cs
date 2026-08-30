using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class PanelAdmitAllTests
{
    [Fact]
    public void Detect_WaitingRoomScopedExactAdmitAll()
    {
        var candidate = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));

        Assert.True(candidate.IsAccepted);
        Assert.Equal(2, candidate.WaitingCount);
        Assert.Equal(new[] { "Ahmed", "Mohab" }, candidate.OriginalParticipants);
        Assert.Equal(0.99, candidate.Confidence, 2);
    }

    [Fact]
    public void Detect_WhenWaitingHeaderAndAdmitAllShareOneOcrLine()
    {
        var lines = new List<OcrLine>
        {
            Line("Participants", 1500, 100, "Participants"),
            Line("Waiting room (2) Admit all", 1500, 200, "Waiting", "room", "(2)", "Admit", "all"),
            Line("Ahmed", 1510, 240, "Ahmed"),
            Line("Mohab", 1510, 275, "Mohab"),
            Line("Joined (2)", 1500, 350, "Joined", "(2)")
        };
        var ocr = new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080));

        var candidate = PanelAdmitAllDetector.Detect(ocr);

        Assert.True(candidate.IsAccepted);
        Assert.Equal(2, candidate.WaitingCount);
        Assert.True(candidate.AdmitAllBounds.X > candidate.Panel.WaitingRoomHeader!.Bounds.X);
    }

    [Fact]
    public void GenericIndividualAdmitDoesNotCountAsAdmitAll()
    {
        Assert.False(PanelAdmitAllDetector.Detect(Panel(["Ahmed"], includeAdmitAll: false, includeIndividualAdmit: true)).IsAccepted);
    }

    [Fact]
    public void AdmitAllHasPriorityOverRowHoverAndMissingAdmitAllLeavesHoverEligible()
    {
        var panel = WaitingRoomParticipantRowDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));
        var admitAll = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));

        Assert.Equal(AutoAdmitPathKind.PanelAdmitAll,
            AutoAdmitPrioritySelector.Choose([], null, admitAll, panel.Rows.First()));
        Assert.Equal(AutoAdmitPathKind.ParticipantsPanel,
            AutoAdmitPrioritySelector.Choose([], null, new PanelAdmitAllCandidate(), panel.Rows.First()));
    }

    [Fact]
    public void MultiPersonNotificationHasPriorityOverAlreadyOpenAdmitAll()
    {
        var multi = new MultiPersonWaitingNotificationCandidate { IsAccepted = true, Confidence = 0.99, WaitingCount = 2 };
        var admitAll = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));

        Assert.Equal(AutoAdmitPathKind.MultiPersonNotification,
            AutoAdmitPrioritySelector.Choose([], multi, admitAll, admitAll.Panel.Rows.First()));
    }

    [Fact]
    public void ViewTransitionRequiresFreshParticipantsAndWaitingRoomPanelEvidence()
    {
        var verifier = new ViewPanelTransitionVerifier();
        var appeared = WaitingRoomParticipantRowDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));
        var neverAppeared = WaitingRoomParticipantRowDetector.Detect(ParticipantsOnly());

        Assert.True(verifier.IsVerified(appeared));
        Assert.False(verifier.IsVerified(neverAppeared));
    }

    [Fact]
    public void OriginalBatchDisappearsEvenWithNewArrival_VerifiesAfterTwoCaptures()
    {
        var original = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));
        var verifier = new BatchAdmissionVerifier(original);
        var zeyadPanel = WaitingRoomParticipantRowDetector.Detect(Panel(["Zeyad"], includeAdmitAll: true));

        Assert.Equal(BatchAdmissionVerificationKind.Pending, verifier.Observe(zeyadPanel).Kind);
        Assert.Equal(BatchAdmissionVerificationKind.Verified, verifier.Observe(zeyadPanel).Kind);
    }

    [Fact]
    public void CountZeroAndWaitingSectionGoneAreStrongVerificationEvidence()
    {
        var original = PanelAdmitAllDetector.Detect(Panel(["Ahmed"], includeAdmitAll: true));
        var zeroVerifier = new BatchAdmissionVerifier(original);
        var zero = WaitingRoomParticipantRowDetector.Detect(Panel([], includeAdmitAll: false));
        Assert.Equal(BatchAdmissionVerificationKind.Pending, zeroVerifier.Observe(zero).Kind);
        Assert.Equal(BatchAdmissionVerificationKind.Verified, zeroVerifier.Observe(zero).Kind);

        var goneVerifier = new BatchAdmissionVerifier(original);
        var participantsOnly = ParticipantsOnly();
        var gone = WaitingRoomParticipantRowDetector.Detect(participantsOnly);
        Assert.Equal(BatchAdmissionVerificationKind.Pending, goneVerifier.Observe(gone).Kind);
        Assert.Equal(BatchAdmissionVerificationKind.Verified, goneVerifier.Observe(gone).Kind);
    }

    [Fact]
    public void SameBatchIsNotClickedTwiceButCanOccurAgainLater()
    {
        var candidate = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));
        var cache = new HandledBatchCache(TimeSpan.FromSeconds(20));
        var now = DateTimeOffset.UtcNow;
        cache.MarkHandled(candidate, now);

        Assert.True(cache.IsSuppressed(candidate, now.AddSeconds(5)));
        Assert.False(cache.IsSuppressed(candidate, now.AddSeconds(21)));
    }

    [Fact]
    public void VerifiedBatchCanBeHandledAgainAsANewEventDuringSameMeeting()
    {
        var candidate = PanelAdmitAllDetector.Detect(Panel(["Ahmed", "Mohab"], includeAdmitAll: true));
        var cache = new HandledBatchCache();
        var now = DateTimeOffset.UtcNow;
        cache.MarkHandled(candidate, now);

        cache.Forget(candidate);

        Assert.False(cache.IsSuppressed(candidate, now.AddSeconds(1)));
    }

    [Fact]
    public void BrowserScreenshotAdmitAllIsRejectedByRuntimeOwnership()
    {
        Assert.False(NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast, "ChatGPT", "class", "title").IsAllowed);
    }

    private static OcrResult Panel(
        string[] participants,
        bool includeAdmitAll,
        bool includeIndividualAdmit = false)
    {
        var lines = new List<OcrLine>
        {
            Line("Participants", 1500, 100, "Participants"),
            Line($"Waiting room ({participants.Length})", 1500, 200, "Waiting", "room", $"({participants.Length})")
        };
        for (int index = 0; index < participants.Length; index++)
            lines.Add(Line(participants[index], 1510, 240 + index * 35, participants[index]));
        if (includeAdmitAll) lines.Add(Line("Admit all", 1730, 315, "Admit", "all"));
        if (includeIndividualAdmit) lines.Add(Line("Admit", 1730, 250, "Admit"));
        lines.Add(Line("Joined (2)", 1500, 350, "Joined", "(2)"));
        return new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080));
    }

    private static OcrResult ParticipantsOnly()
    {
        var line = Line("Participants", 1500, 100, "Participants");
        return new OcrResult([line], line.Words, new(0, 0, 1920, 1080));
    }

    private static OcrLine Line(string text, int x, int y, params string[] tokens)
    {
        int cursor = x;
        var words = tokens.Select(token =>
        {
            int width = Math.Max(20, token.Length * 8);
            var word = new OcrWord(token, new(cursor, y, width, 14));
            cursor += width + 8;
            return word;
        }).ToList();
        return new OcrLine(text, new(x, y, cursor - x - 8, 14), words);
    }
}
