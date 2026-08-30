using System.Text.Json;
using ZoomAutoAdmit.Core.Engines;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.Core.Sessions;
using Xunit;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsMeetingRuntimeIntegrationTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "ZoomAutoAdmitRuntimeTests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task DesktopSuccessfulLifecycleUsesExistingEngineAndStopsCleanly()
    {
        var desktopEngine = new BlockingAutoAdmitEngine("windows");
        var desktopPlatform = new FakeDesktopPlatform();
        var webEngine = new FakeWebLifecycle();
        await using var desktop = new WindowsDesktopMeetingLauncher(desktopEngine, desktopPlatform);
        await using var web = new WindowsWebMeetingLauncher(webEngine, new FakeWebPreparation());
        var coordinator = new SessionCoordinator();
        var orchestrator = CreateOrchestrator("desktop-account", coordinator, desktop, web);

        var session = await orchestrator.RunAsync(Meeting("desktop-account"));

        Assert.Equal(MeetingState.Monitoring, session.State);
        Assert.Equal(SessionEngineType.Desktop, session.Allocation!.EngineType);
        Assert.Equal(1, desktopEngine.StartCount);
        Assert.Equal(
            ["switch", "launch", "verify", "mic-off", "camera-off"],
            desktopPlatform.Calls.Take(5));

        Assert.True(await orchestrator.EndAsync(session));
        Assert.Equal(MeetingState.Ended, session.State);
        Assert.True(desktopEngine.CancellationObserved);
        Assert.Empty(coordinator.ActiveSessions);
    }

    [Fact]
    public async Task WebSuccessfulLifecycleUsesAccountProfileAndStopsCleanly()
    {
        var coordinator = new SessionCoordinator();
        Assert.True(coordinator.Allocate("desktop-owner").IsSuccess);
        var desktop = new WindowsDesktopMeetingLauncher(
            new BlockingAutoAdmitEngine("windows"),
            new FakeDesktopPlatform());
        var webEngine = new FakeWebLifecycle();
        await using var web = new WindowsWebMeetingLauncher(webEngine, new FakeWebPreparation());
        await using (desktop)
        {
            var orchestrator = CreateOrchestrator("web-account", coordinator, desktop, web);

            var session = await orchestrator.RunAsync(Meeting("web-account"));

            Assert.Equal(MeetingState.Monitoring, session.State);
            Assert.Equal(SessionEngineType.Web, session.Allocation!.EngineType);
            Assert.Equal("web-account", session.Allocation.WebProfileName);
            Assert.Equal("web-account", webEngine.StartOptions!.WebProfile);
            Assert.Equal(1, webEngine.MonitorCount);
            Assert.True(await orchestrator.EndAsync(session));
            Assert.True(webEngine.StopCount >= 1);
            Assert.True(webEngine.CancellationObserved);
        }
    }

    [Fact]
    public async Task DesktopLaunchFailureReleasesReservationAndFallsBackToWeb()
    {
        var coordinator = new SessionCoordinator();
        var desktopPlatform = new FakeDesktopPlatform
        {
            LaunchResult = MeetingOperationResult.Failure("Zoom Desktop launch failed.")
        };
        await using var desktop = new WindowsDesktopMeetingLauncher(
            new BlockingAutoAdmitEngine("windows"),
            desktopPlatform);
        var webEngine = new FakeWebLifecycle();
        await using var web = new WindowsWebMeetingLauncher(webEngine, new FakeWebPreparation());
        var orchestrator = CreateOrchestrator("fallback-account", coordinator, desktop, web);

        var session = await orchestrator.RunAsync(Meeting("fallback-account"));

        Assert.Equal(MeetingState.Monitoring, session.State);
        Assert.Equal(SessionEngineType.Web, session.Allocation!.EngineType);
        Assert.Equal("fallback-account", session.Allocation.WebProfileName);
        var active = Assert.Single(coordinator.ActiveSessions);
        Assert.Equal(SessionEngineType.Web, active.EngineType);
        Assert.Equal(session.SessionId, active.SessionId);
    }

    [Fact]
    public async Task InvalidAccountFailsBeforeAllocation()
    {
        var coordinator = new SessionCoordinator();
        await using var desktop = new WindowsDesktopMeetingLauncher(
            new BlockingAutoAdmitEngine("windows"),
            new FakeDesktopPlatform());
        await using var web = new WindowsWebMeetingLauncher(
            new FakeWebLifecycle(),
            new FakeWebPreparation());
        var accountManager = CreateAccountManager("different-account");
        var orchestrator = new MeetingOrchestrator(
            accountManager,
            coordinator,
            new WindowsMeetingRuntimeFactory(desktop, web));

        var session = await orchestrator.RunAsync(Meeting("missing-account"));

        Assert.Equal(MeetingState.Failed, session.State);
        Assert.Contains("could not be loaded", session.FailureReason, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(coordinator.ActiveSessions);
    }

    [Fact]
    public async Task EngineCancellationStopsDesktopAndWebMonitors()
    {
        var desktopEngine = new BlockingAutoAdmitEngine("windows");
        await using var desktop = new WindowsDesktopMeetingLauncher(
            desktopEngine,
            new FakeDesktopPlatform());
        var webEngine = new FakeWebLifecycle();
        await using var web = new WindowsWebMeetingLauncher(webEngine, new FakeWebPreparation());
        var desktopContext = Context(SessionEngineType.Desktop, "desktop-account", null);
        var webContext = Context(SessionEngineType.Web, "web-account", "web-account");
        Assert.True((await desktop.StartAutoAdmitAsync(desktopContext)).IsSuccess);
        Assert.True((await web.LaunchAsync(webContext)).IsSuccess);
        Assert.True((await web.StartAutoAdmitAsync(webContext)).IsSuccess);

        Assert.True((await desktop.StopAutoAdmitAsync(desktopContext)).IsSuccess);
        Assert.True((await web.StopAutoAdmitAsync(webContext)).IsSuccess);

        Assert.True(desktopEngine.CancellationObserved);
        Assert.True(webEngine.CancellationObserved);
    }

    [Fact]
    public async Task FailedDesktopAndWebLaunchesLeaveNoActiveReservation()
    {
        var coordinator = new SessionCoordinator();
        await using var desktop = new WindowsDesktopMeetingLauncher(
            new BlockingAutoAdmitEngine("windows"),
            new FakeDesktopPlatform
            {
                LaunchResult = MeetingOperationResult.Failure("Desktop unavailable.")
            });
        var webEngine = new FakeWebLifecycle { StartFailure = new InvalidOperationException("Web unavailable.") };
        await using var web = new WindowsWebMeetingLauncher(webEngine, new FakeWebPreparation());
        var orchestrator = CreateOrchestrator("failure-account", coordinator, desktop, web);

        var session = await orchestrator.RunAsync(Meeting("failure-account"));

        Assert.Equal(MeetingState.Failed, session.State);
        Assert.Contains("Web unavailable", session.FailureReason);
        Assert.Empty(coordinator.ActiveSessions);
    }

    private MeetingOrchestrator CreateOrchestrator(
        string accountId,
        SessionCoordinator coordinator,
        WindowsDesktopMeetingLauncher desktop,
        WindowsWebMeetingLauncher web) =>
        new(
            CreateAccountManager(accountId),
            coordinator,
            new WindowsMeetingRuntimeFactory(desktop, web));

    private WindowsMeetingAccountManager CreateAccountManager(string accountId)
    {
        Directory.CreateDirectory(_root);
        string path = Path.Combine(_root, $"{Guid.NewGuid():N}.json");
        File.WriteAllText(path, JsonSerializer.Serialize(new[]
        {
            new WindowsMeetingAccountMetadata(
                accountId,
                accountId,
                $"wincred:ZoomAutoAdmit/{accountId}")
        }));
        return new WindowsMeetingAccountManager(path, new AlwaysResolvableCredentialReference());
    }

    private static ScheduledMeeting Meeting(string accountId) =>
        new(new Uri("https://zoom.us/j/123456789"), accountId, DateTimeOffset.UtcNow.AddSeconds(-1));

    private static MeetingLaunchContext Context(
        SessionEngineType engineType,
        string accountId,
        string? webProfile)
    {
        var meeting = Meeting(accountId);
        var session = new MeetingSession(Guid.NewGuid(), meeting, DateTimeOffset.UtcNow);
        var account = new MeetingAccount(accountId, accountId, $"wincred:ZoomAutoAdmit/{accountId}");
        return new MeetingLaunchContext(session, account, engineType, webProfile);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private sealed class AlwaysResolvableCredentialReference : IWindowsCredentialReferenceResolver
    {
        public bool CanResolve(string credentialReference) => true;
    }

    private sealed class BlockingAutoAdmitEngine(string name) : IAutoAdmitEngine
    {
        public string Name { get; } = name;
        public int StartCount { get; private set; }
        public bool CancellationObserved { get; private set; }

        public async Task<int> RunAsync(
            CliOptions options,
            CancellationToken cancellationToken = default)
        {
            StartCount++;
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                CancellationObserved = true;
            }
            return 0;
        }
    }

    private sealed class FakeDesktopPlatform : IWindowsDesktopMeetingPlatform
    {
        public List<string> Calls { get; } = [];
        public MeetingOperationResult SwitchResult { get; init; } = MeetingOperationResult.Success();
        public MeetingOperationResult LaunchResult { get; init; } = MeetingOperationResult.Success();
        public MeetingOperationResult VerifyResult { get; init; } = MeetingOperationResult.Success();

        public Task<MeetingOperationResult> SwitchAccountAsync(
            MeetingAccount account,
            CancellationToken cancellationToken) => Complete("switch", SwitchResult);
        public Task<MeetingOperationResult> LaunchMeetingAsync(
            Uri meetingUrl,
            CancellationToken cancellationToken) => Complete("launch", LaunchResult);
        public Task<MeetingOperationResult> VerifyJoinedAsync(CancellationToken cancellationToken) =>
            Complete("verify", VerifyResult);
        public Task<MeetingOperationResult> DisableMicrophoneAsync(CancellationToken cancellationToken) =>
            Complete("mic-off", MeetingOperationResult.Success());
        public Task<MeetingOperationResult> DisableCameraAsync(CancellationToken cancellationToken) =>
            Complete("camera-off", MeetingOperationResult.Success());
        public Task<MeetingOperationResult> StopAsync(CancellationToken cancellationToken) =>
            Complete("stop", MeetingOperationResult.Success());

        private Task<MeetingOperationResult> Complete(string call, MeetingOperationResult result)
        {
            Calls.Add(call);
            return Task.FromResult(result);
        }
    }

    private sealed class FakeWebLifecycle : IWindowsWebAutoAdmitLifecycle
    {
        public CliOptions? StartOptions { get; private set; }
        public int MonitorCount { get; private set; }
        public int StopCount { get; private set; }
        public bool CancellationObserved { get; private set; }
        public Exception? StartFailure { get; init; }

        public Task StartAsync(CliOptions options, CancellationToken cancellationToken)
        {
            StartOptions = options;
            return StartFailure == null ? Task.CompletedTask : Task.FromException(StartFailure);
        }

        public async Task MonitorAsync(CliOptions options, CancellationToken cancellationToken)
        {
            MonitorCount++;
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                CancellationObserved = true;
                throw;
            }
        }

        public Task StopAsync()
        {
            StopCount++;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeWebPreparation : IWindowsWebMeetingPreparation
    {
        public Task<MeetingOperationResult> DisableMicrophoneAsync(CancellationToken cancellationToken) =>
            Task.FromResult(MeetingOperationResult.Success());
        public Task<MeetingOperationResult> DisableCameraAsync(CancellationToken cancellationToken) =>
            Task.FromResult(MeetingOperationResult.Success());
    }
}
