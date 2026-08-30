using ZoomAutoAdmit.WebAutomation.Models;
using Xunit;

namespace ZoomAutoAdmit.WebAutomation.Tests;

public class WebAdmissionPolicyTests
{
    [Fact]
    public void TwoWaitingParticipantsPreferAdmitAll()
    {
        var snapshot = Snapshot(2, admitAll: true, Participant("Alice"), Participant("Bob"));

        var decision = WebAdmissionPolicy.Decide(snapshot);

        Assert.Equal(WebAdmissionKind.AdmitAll, decision.Kind);
    }

    [Fact]
    public void OneWaitingParticipantUsesExactRowAction()
    {
        var participant = Participant("Alice");

        var decision = WebAdmissionPolicy.Decide(Snapshot(1, false, participant));

        Assert.Equal(WebAdmissionKind.Single, decision.Kind);
        Assert.Equal(participant, decision.Participant);
    }

    [Fact]
    public void MultipleParticipantsWithoutAdmitAllWaitsInsteadOfClickingOneRow()
    {
        var participant = Participant("Alice");

        var decision = WebAdmissionPolicy.Decide(Snapshot(2, false, participant, Participant("Bob")));

        Assert.Equal(WebAdmissionKind.None, decision.Kind);
        Assert.Null(decision.Participant);
    }

    [Fact]
    public void EmptyWaitingRoomHasNoAction()
    {
        Assert.Equal(WebAdmissionKind.None, WebAdmissionPolicy.Decide(Snapshot(0, false)).Kind);
    }

    private static WebWaitingParticipant Participant(string name) =>
        new(name, WebParticipantIdentity.Normalize(name));

    private static WebWaitingRoomSnapshot Snapshot(
        int count,
        bool admitAll,
        params WebWaitingParticipant[] participants) =>
        new(true, true, count, admitAll, participants);
}
