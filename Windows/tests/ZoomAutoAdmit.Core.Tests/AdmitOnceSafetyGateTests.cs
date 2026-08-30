using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class AdmitOnceSafetyGateTests
{
    private static readonly BoundingRectangleInfo Primary = new(0, 0, 1920, 1080);
    private static readonly DateTimeOffset Start = new(2026, 8, 29, 1, 0, 0, TimeSpan.Zero);

    [Fact]
    public void FirstFrameAloneCannotArmFinalClick()
    {
        var gate = new AdmitOnceSafetyGate();
        var candidate = Candidate();

        var first = gate.ObserveConfirmationFrame([candidate], Primary, Start);
        var final = gate.ValidateFinalFrame([candidate], Primary, Start.AddMilliseconds(100), interactiveDesktop: true);

        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted, first.Kind);
        Assert.Equal(AdmitOnceDecisionKind.Rejected, final.Kind);
    }

    [Fact]
    public void TwoMatchingFramesAdvanceToArmed()
    {
        var gate = new AdmitOnceSafetyGate();

        gate.ObserveConfirmationFrame([Candidate()], Primary, Start);
        var result = gate.ObserveConfirmationFrame([Candidate(xOffset: 2)], Primary, Start.AddMilliseconds(200));

        Assert.Equal(AdmitOnceDecisionKind.Armed, result.Kind);
    }

    [Fact]
    public void SixHundredMillisecondProcessingAndNextCaptureAtNineHundredMillisecondsIsNotStale()
    {
        var gate = new AdmitOnceSafetyGate();
        gate.ObserveConfirmationFrame([Candidate()], Primary, Start);

        var result = gate.ObserveConfirmationFrame([Candidate()], Primary, Start.AddMilliseconds(900));

        Assert.Equal(AdmitOnceDecisionKind.Armed, result.Kind);
    }

    [Theory]
    [InlineData(1000)]
    [InlineData(1800)]
    public void StableFramesOneToTwoSecondsApartConfirm(int deltaMilliseconds)
    {
        var gate = new AdmitOnceSafetyGate();
        gate.ObserveConfirmationFrame([Candidate()], Primary, Start);

        var result = gate.ObserveConfirmationFrame([Candidate()], Primary, Start.AddMilliseconds(deltaMilliseconds));

        Assert.Equal(AdmitOnceDecisionKind.Armed, result.Kind);
    }

    [Fact]
    public void ParticipantMismatchRejectsConfirmation()
    {
        var gate = new AdmitOnceSafetyGate();
        gate.ObserveConfirmationFrame([Candidate(participant: "Alice")], Primary, Start);

        var result = gate.ObserveConfirmationFrame([Candidate(participant: "Bob")], Primary, Start.AddMilliseconds(200));

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("participant changed", result.Reason);
    }

    [Fact]
    public void LowConfidenceCandidateIsRejected()
    {
        var gate = new AdmitOnceSafetyGate();

        var result = gate.ObserveConfirmationFrame([Candidate(confidence: 0.94)], Primary, Start);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
    }

    [Fact]
    public void MultipleValidCandidatesAreRejected()
    {
        var gate = new AdmitOnceSafetyGate();

        var result = gate.ObserveConfirmationFrame(
            [Candidate(participant: "Alice"), Candidate(participant: "Bob", xOffset: -300)],
            Primary,
            Start);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("exactly one", result.Reason);
    }

    [Fact]
    public void ExcessiveTargetMovementRejectsConfirmation()
    {
        var gate = new AdmitOnceSafetyGate();
        gate.ObserveConfirmationFrame([Candidate()], Primary, Start);

        var result = gate.ObserveConfirmationFrame([Candidate(xOffset: 20)], Primary, Start.AddMilliseconds(200));

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("moved", result.Reason);
    }

    [Fact]
    public void ChangedAdmitViewRelationshipRejectsConfirmation()
    {
        var gate = new AdmitOnceSafetyGate();
        var first = Candidate();
        var changed = Candidate();
        changed.ViewWord = new OcrWord("View", new(1810, 984, 29, 10));
        gate.ObserveConfirmationFrame([first], Primary, Start);

        var result = gate.ObserveConfirmationFrame([changed], Primary, Start.AddMilliseconds(900));

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("Admit/View relationship", result.Reason);
    }

    [Fact]
    public void StaleSecondFrameIsRejected()
    {
        var gate = new AdmitOnceSafetyGate();
        gate.ObserveConfirmationFrame([Candidate()], Primary, Start);

        var result = gate.ObserveConfirmationFrame(
            [Candidate()],
            Primary,
            Start + AdmitOnceSafetyGate.MaximumConfirmationGap + TimeSpan.FromMilliseconds(1));

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("stale", result.Reason);
    }

    [Fact]
    public void TargetOutsidePrimaryScreenIsRejected()
    {
        var gate = new AdmitOnceSafetyGate();

        var result = gate.ObserveConfirmationFrame([Candidate(xOffset: 500)], new(0, 0, 1000, 700), Start);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("outside Primary Screen", result.Reason);
    }

    [Fact]
    public void SameToastCannotBeMarkedClickedTwice()
    {
        var gate = ArmedGate(out var candidate);

        Assert.True(gate.TryMarkClickSent(candidate, Start.AddMilliseconds(300)));
        Assert.False(gate.TryMarkClickSent(candidate, Start.AddMilliseconds(301)));
        Assert.Equal(
            AdmitOnceDecisionKind.DuplicateRejected,
            gate.ObserveConfirmationFrame([candidate], Primary, Start.AddMilliseconds(400)).Kind);
    }

    [Fact]
    public void FinalThirdFrameFailureAbortsReadiness()
    {
        var gate = ArmedGate(out _);

        var result = gate.ValidateFinalFrame(
            [Candidate(participant: "Different participant")],
            Primary,
            Start.AddMilliseconds(300),
            interactiveDesktop: true);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("participant changed", result.Reason);
    }

    [Fact]
    public void FinalFrameUsesCaptureCompletionTimeAndIgnoresOcrProcessingLatency()
    {
        var gate = new AdmitOnceSafetyGate();
        var candidate = Candidate();
        gate.ObserveConfirmationFrame([candidate], Primary, Start);
        gate.ObserveConfirmationFrame([candidate], Primary, Start.AddMilliseconds(900));

        // The gate receives CaptureCompletedAt. Detection may complete later, but
        // that processing latency must not age the freshly captured pixels.
        var result = gate.ValidateFinalFrame(
            [candidate],
            Primary,
            Start.AddMilliseconds(1800),
            interactiveDesktop: true);

        Assert.Equal(AdmitOnceDecisionKind.ClickReady, result.Kind);
    }

    [Fact]
    public void FinalFrameConflictingGeometryAborts()
    {
        var gate = new AdmitOnceSafetyGate();
        var candidate = Candidate();
        gate.ObserveConfirmationFrame([candidate], Primary, Start);
        gate.ObserveConfirmationFrame([candidate], Primary, Start.AddMilliseconds(500));

        var result = gate.ValidateFinalFrame(
            [Candidate(xOffset: 30)],
            Primary,
            Start.AddMilliseconds(1000),
            interactiveDesktop: true);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("moved", result.Reason);
    }

    [Fact]
    public void LockedDesktopRejectsFinalFrame()
    {
        var gate = ArmedGate(out var candidate);

        var result = gate.ValidateFinalFrame([candidate], Primary, Start.AddMilliseconds(300), interactiveDesktop: false);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
        Assert.Contains("locked", result.Reason);
    }

    [Fact]
    public void MissingOriginalToastVerifiesAdmission()
    {
        var gate = ClickedGate(out _);

        var result = gate.ObserveVerificationFrame([], Start.AddMilliseconds(500), Start.AddSeconds(2));

        Assert.Equal(AdmitOnceDecisionKind.Verified, result.Kind);
    }

    [Fact]
    public void SameTargetAtDeadlineTimesOutVerification()
    {
        var gate = ClickedGate(out var candidate);

        var result = gate.ObserveVerificationFrame([candidate], Start.AddSeconds(2), Start.AddSeconds(2));

        Assert.Equal(AdmitOnceDecisionKind.VerificationTimedOut, result.Kind);
    }

    [Fact]
    public void VisibleTargetBeforeDeadlineIsClickSentButNotYetVerified()
    {
        var gate = ClickedGate(out var candidate);

        var result = gate.ObserveVerificationFrame([candidate], Start.AddMilliseconds(500), Start.AddSeconds(2));

        Assert.Equal(AdmitOnceDecisionKind.VerificationPending, result.Kind);
    }

    [Fact]
    public void CaptureOrOcrEmptyFrameNeverArmsClick()
    {
        var gate = new AdmitOnceSafetyGate();

        var empty = gate.ObserveConfirmationFrame([], Primary, Start);
        var oneGoodFrame = gate.ObserveConfirmationFrame([Candidate()], Primary, Start.AddMilliseconds(100));

        Assert.Equal(AdmitOnceDecisionKind.Rejected, empty.Kind);
        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted, oneGoodFrame.Kind);
    }

    [Fact]
    public void ProvenSplitLineOcrRelationIsAcceptedAndParticipantIsStable()
    {
        var gate = new AdmitOnceSafetyGate();
        var split = Candidate(participant: "eyouth Coordinator entered the");
        split.HeaderLine = new OcrLine("waiting room", new(1618, 939, 97, 16), Array.Empty<OcrWord>());

        var first = gate.ObserveConfirmationFrame([split], Primary, Start);
        var second = gate.ObserveConfirmationFrame([split], Primary, Start.AddMilliseconds(200));

        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted, first.Kind);
        Assert.Equal(AdmitOnceDecisionKind.Armed, second.Kind);
    }

    [Fact]
    public void GenericWaitingRoomTextWithoutEnteredRelationIsRejected()
    {
        var gate = new AdmitOnceSafetyGate();
        var generic = Candidate();
        generic.HeaderLine = new OcrLine("Waiting room", new(1618, 939, 97, 16), Array.Empty<OcrWord>());

        var result = gate.ObserveConfirmationFrame([generic], Primary, Start);

        Assert.Equal(AdmitOnceDecisionKind.Rejected, result.Kind);
    }

    private static AdmitOnceSafetyGate ArmedGate(out WaitingRoomToastCandidate candidate)
    {
        var gate = new AdmitOnceSafetyGate();
        candidate = Candidate();
        gate.ObserveConfirmationFrame([candidate], Primary, Start);
        var armed = gate.ObserveConfirmationFrame([candidate], Primary, Start.AddMilliseconds(200));
        Assert.Equal(AdmitOnceDecisionKind.Armed, armed.Kind);
        return gate;
    }

    private static AdmitOnceSafetyGate ClickedGate(out WaitingRoomToastCandidate candidate)
    {
        var gate = ArmedGate(out candidate);
        var final = gate.ValidateFinalFrame([candidate], Primary, Start.AddMilliseconds(300), interactiveDesktop: true);
        Assert.Equal(AdmitOnceDecisionKind.ClickReady, final.Kind);
        Assert.True(gate.TryMarkClickSent(candidate, Start.AddMilliseconds(300)));
        return gate;
    }

    private static WaitingRoomToastCandidate Candidate(
        string participant = "eyouth Coordinator",
        double confidence = 0.99,
        double xOffset = 0)
    {
        var admitBounds = new BoundingRectangleInfo(1617 + xOffset, 984, 37, 10);
        var viewBounds = new BoundingRectangleInfo(1790 + xOffset, 984, 29, 10);
        var headerBounds = new BoundingRectangleInfo(1618 + xOffset, 917, 231, 38);
        return new WaitingRoomToastCandidate
        {
            ParticipantName = participant,
            ToastBounds = new BoundingRectangleInfo(1603 + xOffset, 902, 246, 107),
            AdmitWord = new OcrWord("Admit", admitBounds),
            ViewWord = new OcrWord("View", viewBounds),
            HeaderLine = new OcrLine(
                $"{participant} entered the waiting room",
                headerBounds,
                Array.Empty<OcrWord>()),
            AdmitCenter = (admitBounds.X + admitBounds.Width / 2, admitBounds.Y + admitBounds.Height / 2),
            Confidence = confidence,
            IsAccepted = true
        };
    }
}
