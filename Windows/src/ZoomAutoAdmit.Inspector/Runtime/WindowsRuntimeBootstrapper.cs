using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Sessions;
using ZoomAutoAdmit.Inspector.Engines;
using ZoomAutoAdmit.WebAutomation;
using ZoomAutoAdmit.WebAutomation.Browser;
using ZoomAutoAdmit.WindowsRuntime;
using ZoomAutoAdmit.WindowsRuntime.Scheduling;

namespace ZoomAutoAdmit.Inspector.Runtime;

public sealed class WindowsRuntimeBootstrapper : IAsyncDisposable
{
    private readonly WindowsDesktopMeetingLauncher _desktopLauncher;
    private readonly WindowsWebMeetingLauncher _webLauncher;

    public WindowsRuntimeBootstrapper(
        string? accountMetadataPath = null,
        string? profilesRoot = null,
        IWindowsCredentialReferenceResolver? credentialResolver = null,
        string? schedulesPath = null,
        IWindowsTaskScheduler? taskScheduler = null)
    {
        ProfileMapper = new WindowsAccountWebProfileMapper(profilesRoot);
        AccountManager = new WindowsMeetingAccountManager(
            accountMetadataPath,
            credentialResolver,
            ProfileMapper);
        SessionCoordinator = new SessionCoordinator();

        _desktopLauncher = new WindowsDesktopMeetingLauncher(
            new WindowsAutoAdmitEngine(),
            new WindowsDesktopMeetingPlatform());
        var webEngine = new WebAutoAdmitEngine(
            profileManager: new ZoomProfileManager(profilesRoot));
        var webLifecycle = new WindowsWebAutoAdmitLifecycle(webEngine);
        _webLauncher = new WindowsWebMeetingLauncher(
            webLifecycle,
            new WindowsWebMeetingPreparation(webLifecycle));
        RuntimeFactory = new WindowsMeetingRuntimeFactory(_desktopLauncher, _webLauncher);
        Orchestrator = new MeetingOrchestrator(
            AccountManager,
            SessionCoordinator,
            RuntimeFactory);
        TaskScheduler = taskScheduler ?? new WindowsTaskSchedulerService();
        ScheduleStore = new WindowsMeetingScheduleStore(schedulesPath, TaskScheduler);
        Scheduler = new WindowsMeetingScheduler(
            ScheduleStore,
            new OrchestratedScheduledMeetingRunner(Orchestrator));
        ConsoleLogger.Success("[BOOTSTRAP] Services initialized");
    }

    public WindowsMeetingAccountManager AccountManager { get; }
    public WindowsAccountWebProfileMapper ProfileMapper { get; }
    public SessionCoordinator SessionCoordinator { get; }
    public WindowsMeetingRuntimeFactory RuntimeFactory { get; }
    public MeetingOrchestrator Orchestrator { get; }
    public IWindowsTaskScheduler TaskScheduler { get; }
    public WindowsMeetingScheduleStore ScheduleStore { get; }
    public WindowsMeetingScheduler Scheduler { get; }

    public async ValueTask DisposeAsync()
    {
        await Scheduler.DisposeAsync();
        await _webLauncher.DisposeAsync();
        await _desktopLauncher.DisposeAsync();
    }
}
