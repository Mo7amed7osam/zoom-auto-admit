using Xunit;
using ZoomAutoAdmit.Core.Meetings;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsKeyboardAccountSwitcherTests
{
    [Fact]
    public void ExistingHiddenWindowIsShownWithoutLaunchingAnotherProcess()
    {
        IntPtr shown = IntPtr.Zero;
        var result = WindowsKeyboardAccountSwitcher.EnsureMainWindow(() => (IntPtr)123,
            () => throw new Exception("Must not launch"), h => shown = h,
            () => throw new Exception("Must not wait"), CancellationToken.None);
        Assert.Equal((IntPtr)123, result);
        Assert.Equal(result, shown);
    }

    [Fact]
    public void ClosedZoomLaunchesOnceAndWaitsForHomeWindow()
    {
        int searches = 0, launches = 0, waits = 0;
        IntPtr shown = IntPtr.Zero;
        var result = WindowsKeyboardAccountSwitcher.EnsureMainWindow(
            () => ++searches >= 3 ? (IntPtr)456 : IntPtr.Zero,
            () => launches++, h => shown = h, () => waits++, CancellationToken.None);
        Assert.Equal(1, launches);
        Assert.Equal(2, waits);
        Assert.Equal((IntPtr)456, result);
        Assert.Equal(result, shown);
    }

    [Fact]
    public void StartupTimeoutDoesNotSendInput()
    {
        int launches = 0;
        Assert.Throws<InvalidOperationException>(() => WindowsKeyboardAccountSwitcher.EnsureMainWindow(
            () => IntPtr.Zero, () => launches++, _ => throw new Exception("Must not show"),
            () => { }, CancellationToken.None, attempts: 2));
        Assert.Equal(1, launches);
    }

    [Fact]
    public void CancellationDuringStartupDoesNotShowWindow()
    {
        using var cts = new CancellationTokenSource();
        Assert.Throws<OperationCanceledException>(() => WindowsKeyboardAccountSwitcher.EnsureMainWindow(
            () => IntPtr.Zero, () => { }, _ => throw new Exception("Must not show"),
            cts.Cancel, cts.Token));
    }

    [Theory]
    [InlineData("eyouth coordinator, depi+21@eyouthlearning.com, Menu item", true)]
    [InlineData("eyouth coordinator, depi+210@eyouthlearning.com, Menu item", false)]
    [InlineData("eyouth coordinator, otherdepi+21@eyouthlearning.com, Menu item", false)]
    [InlineData("eyouth coordinator, depi+21@eyouthlearning.com.evil, Menu item", false)]
    [InlineData("eyouth coordinator", false)]
    public void MatchingUsesExactEmailNotDisplayNameOrPosition(string name, bool expected) =>
        Assert.Equal(expected, WindowsKeyboardAccountSwitcher.ContainsEmail(name, "depi+21@eyouthlearning.com"));

    [Theory]
    [InlineData("eyouth, email@example.com, Current active account, Menu item, 1 of 5", 4u, true)]
    [InlineData("eyouth, email@example.com, Menu item, 2 of 5", 4u, false)]
    [InlineData("eyouth, email@example.com, Menu item, 2 of 5", 16u, true)]
    public void VerificationRequiresActiveMarkerNotFocus(string name, uint state, bool expected) =>
        Assert.Equal(expected, WindowsKeyboardAccountSwitcher.IsActiveAccount(name, state));

    [Fact]
    public async Task PlatformPropagatesKeyboardFailure()
    {
        var platform = new WindowsDesktopMeetingPlatform(_ => "test@example.com",
            (_, _) => Task.FromResult(MeetingOperationResult.Failure("Zoom lost foreground; no input sent.")));
        var result = await platform.SwitchAccountAsync(new MeetingAccount("id", "name", "ref"), CancellationToken.None);
        Assert.False(result.IsSuccess);
        Assert.Contains("lost foreground", result.ErrorMessage);
    }

    [Fact]
    public async Task CancelledPlatformCallDoesNotResolveCredentialsOrSendInput()
    {
        var platform = new WindowsDesktopMeetingPlatform(_ => throw new Exception("Must not resolve"),
            (_, _) => throw new Exception("Must not switch"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => platform.SwitchAccountAsync(
            new MeetingAccount("id", "name", "ref"), new CancellationToken(true)));
    }
}
