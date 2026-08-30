using ZoomAutoAdmit.Core.Matching;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class ProfileButtonMatcherTests
{
    [Theory]
    [InlineData("SplitButton", "Zoom, eyouth coordinator, Status, Available, Licensed account", true, true, true)]
    [InlineData("Button", "Zoom, John Doe, Status, Busy, Basic account", true, true, true)]
    [InlineData("SplitButton", "Zoom, Test User, Status, In a meeting", true, true, true)]
    [InlineData("SplitButton", "Zoom, Test User, Status, Available", true, false, false)] // No InvokePattern
    [InlineData("SplitButton", "Zoom, Test User, Status, Available", false, true, false)] // Disabled
    [InlineData("Pane", "Zoom, Test User, Status, Available", true, true, false)] // Wrong ControlType
    [InlineData("SplitButton", "Schedule a meeting", true, true, false)] // Irrelevant Name
    [InlineData("SplitButton", "Sign Out", true, true, false)] // Dangerous action
    public void IsProfileSplitButton_ValidatesCorrectly(
        string controlType,
        string name,
        bool isEnabled,
        bool hasInvoke,
        bool expected)
    {
        var result = ProfileButtonMatcher.IsProfileSplitButton(controlType, name, isEnabled, hasInvoke);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("Zoom, eyouth coordinator, Status, Available, Licensed account", true, "eyouth coordinator")]
    [InlineData("Zoom, John Doe, Status, Busy", true, "John Doe")]
    [InlineData("Invalid format", false, "")]
    [InlineData("", false, "")]
    public void TryExtractDisplayName_ExtractsCorrectly(string name, bool expectedOk, string expectedDisplayName)
    {
        var ok = ProfileButtonMatcher.TryExtractDisplayName(name, out var displayName);
        Assert.Equal(expectedOk, ok);
        if (expectedOk)
        {
            Assert.Equal(expectedDisplayName, displayName);
        }
    }
}
