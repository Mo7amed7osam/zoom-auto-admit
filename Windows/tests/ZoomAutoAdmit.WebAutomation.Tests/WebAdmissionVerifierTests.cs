using ZoomAutoAdmit.WebAutomation.Models;
using Xunit;

namespace ZoomAutoAdmit.WebAutomation.Tests;

public class WebAdmissionVerifierTests
{
    [Fact]
    public void NotificationDisappearanceConfirmsNotificationAdmission()
    {
        var participant = Participant("Alice");
        var before = Snapshot(1, participant) with
        {
            ArrivalNotificationParticipantIdentities = [participant.Identity]
        };
        var after = Snapshot(1, participant);
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, participant, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, after, action);

        Assert.True(result.IsVerified);
        Assert.Contains("notification disappeared", result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SingleAdmissionConfirmsWhenParticipantDisappearsAndCountDecreases()
    {
        var alice = Participant("Alice");
        var bob = Participant("Bob");
        var before = Snapshot(2, alice, bob);
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, alice, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, Snapshot(1, bob), action);

        Assert.True(result.IsVerified);
        Assert.False(result.ShouldRetry);
    }

    [Fact]
    public void ParticipantStillWaitingRequestsRetry()
    {
        var alice = Participant("Alice");
        var before = Snapshot(1, alice);
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, alice, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, Snapshot(1, alice), action);

        Assert.False(result.IsVerified);
        Assert.True(result.ShouldRetry);
    }

    [Fact]
    public void DelayedCountDecreaseConfirmsAfterEarlierRetry()
    {
        var alice = Participant("Alice");
        var before = Snapshot(2, alice, Participant("Bob"));
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, alice, string.Empty);

        var whileUpdating = WebAdmissionVerifier.Evaluate(before, Snapshot(2, alice, Participant("Bob")), action);
        var afterDelayedUpdate = WebAdmissionVerifier.Evaluate(before, Snapshot(1, alice), action);

        Assert.False(whileUpdating.IsVerified);
        Assert.True(whileUpdating.ShouldRetry);
        Assert.True(afterDelayedUpdate.IsVerified);
    }

    [Fact]
    public void ParticipantDisappearanceConfirmsBeforeDelayedCountUpdate()
    {
        var alice = Participant("Alice");
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, alice, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(
            Snapshot(1, alice),
            Snapshot(1),
            action);

        Assert.True(result.IsVerified);
        Assert.Contains("disappeared", result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ParticipantAppearingInJoinedListConfirmsAdmission()
    {
        var alice = Participant("Alice");
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, alice, string.Empty);
        var after = Snapshot(1, alice) with
        {
            JoinedParticipantIdentities = [alice.Identity]
        };

        var result = WebAdmissionVerifier.Evaluate(Snapshot(1, alice), after, action);

        Assert.True(result.IsVerified);
        Assert.Contains("Joined", result.Reason);
    }

    [Fact]
    public void ExistingJoinedParticipantWithSameNameDoesNotConfirmWaitingDuplicate()
    {
        var participant = Participant("eyouth coordinator");
        var before = Snapshot(1, participant) with
        {
            JoinedParticipantIdentities = [participant.Identity]
        };
        var after = Snapshot(1, participant) with
        {
            JoinedParticipantIdentities = [participant.Identity]
        };
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, participant, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, after, action);

        Assert.False(result.IsVerified);
        Assert.True(result.ShouldRetry);
    }

    [Fact]
    public void SecondJoinedParticipantWithSameNameConfirmsByOccurrenceCount()
    {
        var participant = Participant("eyouth coordinator");
        var before = Snapshot(1, participant) with
        {
            JoinedParticipantIdentities = [participant.Identity]
        };
        var after = Snapshot(1, participant) with
        {
            JoinedParticipantIdentities = [participant.Identity, participant.Identity]
        };
        var action = new WebAdmissionDecision(WebAdmissionKind.Single, participant, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, after, action);

        Assert.True(result.IsVerified);
    }

    [Fact]
    public void AdmitAllRequiresCountDecreaseAndOriginalBatchGone()
    {
        var before = Snapshot(2, Participant("Alice"), Participant("Bob"));
        var action = new WebAdmissionDecision(WebAdmissionKind.AdmitAll, null, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, Snapshot(0), action);

        Assert.True(result.IsVerified);
    }

    [Fact]
    public void AdmitAllCountDecreaseConfirmsEvenWhenIdentitiesAreDelayed()
    {
        var before = Snapshot(3);
        var action = new WebAdmissionDecision(WebAdmissionKind.AdmitAll, null, string.Empty);

        var result = WebAdmissionVerifier.Evaluate(before, Snapshot(2), action);

        Assert.True(result.IsVerified);
    }

    private static WebWaitingParticipant Participant(string name) =>
        new(name, WebParticipantIdentity.Normalize(name));

    private static WebWaitingRoomSnapshot Snapshot(int count, params WebWaitingParticipant[] participants) =>
        new(true, true, count, false, participants);
}
