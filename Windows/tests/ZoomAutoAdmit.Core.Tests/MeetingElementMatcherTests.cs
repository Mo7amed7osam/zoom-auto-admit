using ZoomAutoAdmit.Core.Matching;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class MeetingElementMatcherTests
{
    [Theory]
    [InlineData("Zoom Meeting", "ZPMeetingUIWndClass", true)]
    [InlineData("Zoom Meeting", "", true)]
    [InlineData("Zoom", "ZPPTMainFrmWndClassEx", false)]
    [InlineData("", "ZPFloatToolbarWndClass", true)]
    [InlineData("Weekly Standup - Zoom Meeting", "WindowsForms10", true)]
    public void IsMeetingWindow_ClassifiesCorrectly(string title, string className, bool expected)
    {
        var result = MeetingElementMatcher.IsMeetingWindow(title, className);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("Participants (2)", "", "", "Pane", true)]
    [InlineData("participants_panel", "", "", "Custom", true)]
    [InlineData("Chat", "", "", "Pane", false)]
    public void IsParticipantsPanel_ClassifiesCorrectly(string name, string automationId, string className, string controlType, bool expected)
    {
        var result = MeetingElementMatcher.IsParticipantsPanel(name, automationId, className, controlType);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("Waiting Room (1)", "", true)]
    [InlineData("", "In Waiting Room", true)]
    [InlineData("In Meeting (2)", "", false)]
    public void IsWaitingRoomSection_ClassifiesCorrectly(string name, string legacyName, bool expected)
    {
        var result = MeetingElementMatcher.IsWaitingRoomSection(name, legacyName);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("Admit", "", "Button", true)]
    [InlineData("Admit John Doe", "", "Button", true)]
    [InlineData("Admit", "", "Pane", false)]
    [InlineData("Mute", "", "Button", false)]
    public void IsAdmitButton_ClassifiesCorrectly(string name, string legacyName, string controlType, bool expected)
    {
        var result = MeetingElementMatcher.IsAdmitButton(name, legacyName, controlType);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("Admit all", "", "Button", true)]
    [InlineData("Admit All (3)", "", "Button", true)]
    [InlineData("Admit", "", "Button", false)]
    public void IsAdmitAllButton_ClassifiesCorrectly(string name, string legacyName, string controlType, bool expected)
    {
        var result = MeetingElementMatcher.IsAdmitAllButton(name, legacyName, controlType);
        Assert.Equal(expected, result);
    }
}
