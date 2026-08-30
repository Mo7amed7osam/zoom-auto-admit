using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

/// <summary>
/// UNIT TESTED: Tests for CLI arguments parsing and options mapping.
/// </summary>
public class InspectionOptionsTests
{
    [Fact]
    public void Parse_DefaultArgs_ReturnsInspectCommandWithDefaults()
    {
        var options = CliOptions.Parse(Array.Empty<string>());

        Assert.Equal("inspect", options.Command);
        Assert.False(options.ShowAll);
        Assert.Equal(15, options.MaxDepth);
        Assert.Equal(800, options.MaxElements);
        Assert.Null(options.TargetProcessId);
        Assert.Null(options.Query);
    }

    [Fact]
    public void Parse_InspectAll_SetsHighLimits()
    {
        var options = CliOptions.Parse(new[] { "inspect", "--all" });

        Assert.Equal("inspect", options.Command);
        Assert.True(options.ShowAll);
        Assert.True(options.MaxDepth >= 30);
        Assert.True(options.MaxElements >= 2000);
    }

    [Fact]
    public void Parse_FindCommand_CapturesQuery()
    {
        var options = CliOptions.Parse(new[] { "find", "Admit All" });

        Assert.Equal("find", options.Command);
        Assert.Equal("Admit All", options.Query);
    }

    [Fact]
    public void Parse_CustomLimitsAndPid_CapturesValues()
    {
        var options = CliOptions.Parse(new[] { "inspect", "--max-depth", "25", "--max-elements", "1200", "--pid", "9988" });

        Assert.Equal("inspect", options.Command);
        Assert.Equal(25, options.MaxDepth);
        Assert.Equal(1200, options.MaxElements);
        Assert.Equal(9988, options.TargetProcessId);
    }

    [Theory]
    [InlineData(new[] { "account-menu-capture", "--delay", "10" }, "account-menu-capture", 10)]
    [InlineData(new[] { "account-menu-capture", "-w", "3" }, "account-menu-capture", 3)]
    [InlineData(new[] { "account-menu-capture" }, "account-menu-capture", 5)]
    public void Parse_AccountMenuCapture_ParsesDelayCorrectly(string[] args, string expectedCmd, int expectedDelay)
    {
        var options = CliOptions.Parse(args);

        Assert.Equal(expectedCmd, options.Command);
        Assert.Equal(expectedDelay, options.DelaySeconds);
    }

    [Fact]
    public void Parse_DefaultTimeout_Returns20()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch" });

        Assert.Equal("profile-menu-watch", options.Command);
        Assert.Equal(20, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutExplicit_ParsesCorrectly()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "--timeout", "20" });

        Assert.Equal("profile-menu-watch", options.Command);
        Assert.Equal(20, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutShortFlag_ParsesCorrectly()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "-t", "30" });

        Assert.Equal("profile-menu-watch", options.Command);
        Assert.Equal(30, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutTooLow_ClampedToMinimum5()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "--timeout", "2" });

        Assert.Equal(5, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutTooHigh_ClampedToMaximum120()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "--timeout", "999" });

        Assert.Equal(120, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutInvalidValue_KeepsDefault()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "--timeout", "abc" });

        Assert.Equal(20, options.TimeoutSeconds);
    }

    [Fact]
    public void Parse_TimeoutDoesNotAffectDelay()
    {
        var options = CliOptions.Parse(new[] { "profile-menu-watch", "--timeout", "30", "--delay", "10" });

        Assert.Equal(30, options.TimeoutSeconds);
        Assert.Equal(10, options.DelaySeconds);
    }

    [Theory]
    [InlineData("0", 0)]
    [InlineData("300", 300)]
    public void Parse_AutoAdmit_AllowsContinuousAndBoundedTimeouts(string value, int expected)
    {
        var options = CliOptions.Parse(new[] { "waiting-room-auto-admit", "--timeout", value });

        Assert.Equal(expected, options.TimeoutSeconds);
        Assert.True(options.TimeoutExplicitlySet);
    }

    [Fact]
    public void Parse_MeetingWatchCommand_ParsesCorrectly()
    {
        var options = CliOptions.Parse(new[] { "meeting-watch", "--timeout", "60", "--max-depth", "25", "--max-elements", "2000" });

        Assert.Equal("meeting-watch", options.Command);
        Assert.Equal(60, options.TimeoutSeconds);
        Assert.Equal(25, options.MaxDepth);
        Assert.Equal(2000, options.MaxElements);
    }

    [Fact]
    public void Parse_WebEngineOptions_UsesManagedProfileMeetingUrlAndClampedPollInterval()
    {
        var options = CliOptions.Parse([
            "waiting-room-auto-admit",
            "--engine", "web",
            "--profile", "account1",
            "--meeting-url", "https://example.zoom.us/j/123456789",
            "--headed",
            "--poll-ms", "200"
        ]);

        Assert.Equal("web", options.Engine);
        Assert.Equal("account1", options.WebProfile);
        Assert.Equal("https://example.zoom.us/j/123456789", options.MeetingUrl);
        Assert.True(options.WebHeaded);
        Assert.Equal(500, options.WebPollIntervalMilliseconds);
    }

    [Fact]
    public void Parse_AutoAdmitEngineDefaultsToWindows()
    {
        var options = CliOptions.Parse(["waiting-room-auto-admit"]);

        Assert.Equal("windows", options.Engine);
        Assert.Equal("default", options.WebProfile);
        Assert.Null(options.MeetingUrl);
        Assert.Equal(750, options.WebPollIntervalMilliseconds);
    }
}
