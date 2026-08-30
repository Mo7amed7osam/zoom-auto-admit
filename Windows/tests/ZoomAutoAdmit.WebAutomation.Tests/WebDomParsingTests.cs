using Xunit;

namespace ZoomAutoAdmit.WebAutomation.Tests;

public class WebDomParsingTests
{
    [Theory]
    [InlineData("Waiting room (3)", 3)]
    [InlineData("Waiting   room (12)", 12)]
    [InlineData("Waiting room 4", 4)]
    public void WaitingCountComesFromDomHeader(string text, int expected)
    {
        Assert.Equal(expected, ZoomWaitingRoomDom.ParseWaitingCount(text));
    }

    [Fact]
    public void ArrivalToastIsNotMistakenForWaitingRoomHeader()
    {
        Assert.Null(ZoomWaitingRoomDom.ParseWaitingCount(
            "eyouth coordinator entered the waiting room"));
    }

    [Fact]
    public void ParticipantIdentityRemovesGuestAndDomActionLabels()
    {
        string name = WebParticipantIdentity.FromRowText(
            "Waiting room (1) View Mohab Mohamed _Coordinator (Guest) Admit More");

        Assert.Equal("Mohab Mohamed _Coordinator", name);
        Assert.Equal("MOHAB MOHAMED _COORDINATOR", WebParticipantIdentity.Normalize(name));
    }

    [Fact]
    public void ViewOnlyActionContainerIsNotAValidParticipantName()
    {
        Assert.Equal(string.Empty, WebParticipantIdentity.FromRowText("View Admit More"));
    }
}
