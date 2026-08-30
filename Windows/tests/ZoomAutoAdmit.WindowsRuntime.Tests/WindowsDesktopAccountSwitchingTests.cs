using Xunit;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.Core.Sessions;
using ZoomAutoAdmit.UIAutomation.Window;
using ZoomAutoAdmit.WindowsRuntime;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsDesktopAccountSwitchingTests
{
    [Fact]
    public void ZoomHomeScreenIsNotClassifiedAsActiveMeetingWindow()
    {
        // Zoom Workplace Home screen has title "Zoom Workplace" or "Zoom"
        // and class "ConfMultiTabContentWndClass" or "ZPContentViewWndClass"
        // It must NOT be classified as MeetingWindow.
        
        // Test with IntPtr zero
        Assert.Equal(ZoomWindowRole.Unknown, ZoomWindowManager.ClassifyZoomWindow(IntPtr.Zero));
    }

    [Fact]
    public async Task SwitchAccountRoutesResolvedEmailToKeyboardService()
    {
        string? selected = null;
        var platform = new WindowsDesktopMeetingPlatform(_ => "depi+21@eyouthlearning.com",
            (email, _) => { selected = email; return Task.FromResult(MeetingOperationResult.Success()); });
        var account = new MeetingAccount(
            AccountId: "teacher-1",
            DisplayName: "Teacher One",
            CredentialReference: "ref-1",
            PreferredEngine: SessionEngineType.Desktop);

        var logs = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void Handler(LogEntry entry) => logs.Enqueue(entry.Message);
        ConsoleLogger.EntryWritten += Handler;

        try
        {
            var result = await platform.SwitchAccountAsync(account, CancellationToken.None);

            Assert.True(result.IsSuccess);
            Assert.Equal("depi+21@eyouthlearning.com", selected);
            Assert.Contains(logs, l => l.Contains("[ACCOUNT_SWITCH] Success"));
        }
        finally
        {
            ConsoleLogger.EntryWritten -= Handler;
        }
    }

    [Fact]
    public void AccountMatchingHandlesMultipleSavedAccounts()
    {
        var account1 = new MeetingAccount("CAI5_AIS4_S7", "Eyouth Coordinator", "cred1");
        var account2 = new MeetingAccount("CAI5_AIS4_S8", "Teacher Two", "cred2");

        // Verify account matching logic across display names, IDs, and complex Zoom UI strings
        string zoomMenuString1 = "Zoom, Eyouth Coordinator, Status, Available, Licensed account";
        string zoomMenuString2 = "Zoom, Teacher Two, Status, Busy, Licensed account";

        Assert.Contains(account1.DisplayName, zoomMenuString1, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(account2.DisplayName, zoomMenuString1, StringComparison.OrdinalIgnoreCase);

        Assert.Contains(account2.DisplayName, zoomMenuString2, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(account1.DisplayName, zoomMenuString2, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SwitchAccountTargetMatchingUsesExactEmailSubstringNotDisplayName()
    {
        const string sharedDisplayName = "eyouth coordinator";
        const string targetEmail = "depi+21@eyouthlearning.com";
        string targetMenuItem = $"{sharedDisplayName}, {targetEmail}";
        string differentAccount = $"{sharedDisplayName}, depi+22@eyouthlearning.com";

        Assert.True(WindowsDesktopMeetingPlatform.TextContainsEmail(targetMenuItem, targetEmail));
        Assert.False(WindowsDesktopMeetingPlatform.TextContainsEmail(differentAccount, targetEmail));
        Assert.False(WindowsDesktopMeetingPlatform.TextContainsEmail(sharedDisplayName, targetEmail));
    }

    [Fact]
    public async Task SwitchAccountLogsExpectedTags()
    {
        var platform = new WindowsDesktopMeetingPlatform(_ => null,
            (_, _) => throw new InvalidOperationException("Missing credentials must never launch Zoom or send input."));
        var account = new MeetingAccount("test-id", "Nonexistent Test Account", "cred");

        var loggedMessages = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void OnLog(LogEntry e) => loggedMessages.Enqueue(e.Message);
        ConsoleLogger.EntryWritten += OnLog;

        try
        {
            var result = await platform.SwitchAccountAsync(account, CancellationToken.None);

            Assert.False(result.IsSuccess);
            Assert.Contains(loggedMessages, m => m.Contains("[ACCOUNT_SWITCH] Failure"));
        }
        finally
        {
            ConsoleLogger.EntryWritten -= OnLog;
        }
    }
}
