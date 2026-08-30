using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Sessions;

namespace ZoomAutoAdmit.Core.Meetings;

public sealed record MeetingAccount(
    string AccountId,
    string DisplayName,
    string CredentialReference);

public interface IMeetingAccountManager
{
    Task<MeetingAccount?> LoadAsync(string accountId, CancellationToken cancellationToken = default);
}

public sealed record MeetingOperationResult(bool IsSuccess, string? ErrorMessage)
{
    public static MeetingOperationResult Success() => new(true, null);
    public static MeetingOperationResult Failure(string message) => new(false, message);
}

public sealed record MeetingLaunchContext(
    MeetingSession Session,
    MeetingAccount Account,
    SessionEngineType EngineType,
    string? WebProfileName);

/// <summary>
/// Adapter boundary between orchestration and the existing Desktop/Web implementations.
/// Implementations may delegate to the current account switcher, meeting launcher, media
/// controls, and Auto Admit engine without changing those components.
/// </summary>
public interface IMeetingEngineRuntime
{
    SessionEngineType EngineType { get; }
    Task<MeetingOperationResult> SwitchAccountAsync(
        MeetingAccount account,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> LaunchAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> VerifyJoinedAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> DisableMicrophoneAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> DisableCameraAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> StartAutoAdmitAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
    Task<MeetingOperationResult> StopAutoAdmitAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default);
}

public interface IMeetingEngineRuntimeFactory
{
    IMeetingEngineRuntime Get(SessionEngineType engineType);
}

public sealed class MeetingOrchestrator
{
    private readonly IMeetingAccountManager _accountManager;
    private readonly SessionCoordinator _sessionCoordinator;
    private readonly IMeetingEngineRuntimeFactory _runtimeFactory;

    public MeetingOrchestrator(
        IMeetingAccountManager accountManager,
        SessionCoordinator sessionCoordinator,
        IMeetingEngineRuntimeFactory runtimeFactory)
    {
        _accountManager = accountManager ?? throw new ArgumentNullException(nameof(accountManager));
        _sessionCoordinator = sessionCoordinator ?? throw new ArgumentNullException(nameof(sessionCoordinator));
        _runtimeFactory = runtimeFactory ?? throw new ArgumentNullException(nameof(runtimeFactory));
    }

    public async Task<MeetingSession> RunAsync(
        ScheduledMeeting meeting,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        Guid sessionId = meeting.SessionId ?? Guid.NewGuid();
        var session = new MeetingSession(sessionId, meeting, DateTimeOffset.UtcNow);
        ConsoleLogger.Info($"[SESSION] Created: {session.SessionId}");

        try
        {
            TimeSpan delay = meeting.StartTime - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero)
                await Task.Delay(delay, cancellationToken);

            var account = await _accountManager.LoadAsync(meeting.AccountId, cancellationToken);
            if (account == null)
                return Fail(session, "The requested account could not be loaded.");

            var allocationResult = _sessionCoordinator.Allocate(
                meeting.AccountId,
                meeting.StartTime,
                sessionId);
            if (!allocationResult.IsSuccess || allocationResult.Session == null)
                return Fail(session, allocationResult.ErrorMessage ?? "Engine allocation failed.");

            var allocation = allocationResult.Session;
            session.SetAllocation(allocation);
            ConsoleLogger.Info($"[ALLOCATOR] {allocation.EngineType} selected");
            _sessionCoordinator.TryUpdateStatus(sessionId, SessionStatus.Starting, out _);

            var runtime = _runtimeFactory.Get(allocation.EngineType);
            if (runtime.EngineType != allocation.EngineType)
                return Fail(session, "The selected meeting runtime does not match the allocated engine.");

            var context = new MeetingLaunchContext(
                session,
                account,
                allocation.EngineType,
                allocation.WebProfileName);

            if (allocation.EngineType == SessionEngineType.Desktop)
            {
                session.TransitionTo(MeetingState.SwitchingAccount, "Switching Zoom Desktop account.");
                ConsoleLogger.Info("[SESSION] Switching account");
                var switchResult = await runtime.SwitchAccountAsync(account, cancellationToken);
                if (!switchResult.IsSuccess)
                    return Fail(session, switchResult.ErrorMessage ?? "Zoom Desktop account switch failed.");
            }

            session.TransitionTo(MeetingState.Launching, "Launching the allocated meeting engine.");
            ConsoleLogger.Info("[MEETING] Launching");
            var launchResult = await runtime.LaunchAsync(context, cancellationToken);
            if (!launchResult.IsSuccess && allocation.EngineType == SessionEngineType.Desktop)
            {
                ConsoleLogger.Warn("[ALLOCATOR] Desktop launch failed; releasing Desktop reservation");
                await runtime.StopAutoAdmitAsync(context, cancellationToken);
                _sessionCoordinator.Release(sessionId);

                var webAllocationResult = _sessionCoordinator.AllocateWeb(
                    meeting.AccountId,
                    meeting.StartTime,
                    sessionId);
                if (!webAllocationResult.IsSuccess || webAllocationResult.Session == null)
                    return Fail(
                        session,
                        webAllocationResult.ErrorMessage ?? "Web fallback allocation failed.");

                allocation = webAllocationResult.Session;
                session.SetAllocation(allocation);
                _sessionCoordinator.TryUpdateStatus(sessionId, SessionStatus.Starting, out _);
                ConsoleLogger.Info("[ALLOCATOR] Web selected after Desktop launch failure");
                runtime = _runtimeFactory.Get(SessionEngineType.Web);
                if (runtime.EngineType != SessionEngineType.Web)
                    return Fail(session, "The Web fallback runtime is not available.");
                context = new MeetingLaunchContext(
                    session,
                    account,
                    SessionEngineType.Web,
                    allocation.WebProfileName);
                launchResult = await runtime.LaunchAsync(context, cancellationToken);
            }
            if (!launchResult.IsSuccess)
                return Fail(session, launchResult.ErrorMessage ?? "Meeting launch failed.");

            session.TransitionTo(MeetingState.Joining, "Waiting for the meeting to be joined.");
            ConsoleLogger.Info("[MEETING] Joining");
            var joinedResult = await runtime.VerifyJoinedAsync(context, cancellationToken);
            if (!joinedResult.IsSuccess)
                return Fail(session, joinedResult.ErrorMessage ?? "Meeting join verification failed.");

            session.TransitionTo(MeetingState.Preparing, "Preparing microphone and camera state.");
            var microphoneResult = await runtime.DisableMicrophoneAsync(context, cancellationToken);
            if (!microphoneResult.IsSuccess)
                return Fail(session, microphoneResult.ErrorMessage ?? "Microphone could not be disabled.");
            ConsoleLogger.Success("[PREPARE] Mic disabled");

            var cameraResult = await runtime.DisableCameraAsync(context, cancellationToken);
            if (!cameraResult.IsSuccess)
                return Fail(session, cameraResult.ErrorMessage ?? "Camera could not be disabled.");
            ConsoleLogger.Success("[PREPARE] Camera disabled");

            session.TransitionTo(MeetingState.Active, "Meeting joined and prepared.");
            _sessionCoordinator.TryUpdateStatus(sessionId, SessionStatus.Active, out _);

            var monitorResult = await runtime.StartAutoAdmitAsync(context, cancellationToken);
            if (!monitorResult.IsSuccess)
                return Fail(session, monitorResult.ErrorMessage ?? "Auto Admit monitor failed to start.");

            session.TransitionTo(MeetingState.Monitoring, "Auto Admit monitor started.");
            ConsoleLogger.Success("[AUTO_ADMIT] Started");
            return session;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return Fail(session, "Meeting session startup was cancelled.");
        }
        catch (Exception ex)
        {
            return Fail(session, ex.Message);
        }
    }

    public async Task<bool> EndAsync(
        MeetingSession session,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        var allocation = session.Allocation;
        if (allocation == null || session.State is MeetingState.Ended or MeetingState.Failed)
            return false;

        var account = await _accountManager.LoadAsync(session.AccountId, cancellationToken);
        if (account == null) return false;
        var runtime = _runtimeFactory.Get(allocation.EngineType);
        var context = new MeetingLaunchContext(
            session,
            account,
            allocation.EngineType,
            allocation.WebProfileName);
        var stopped = await runtime.StopAutoAdmitAsync(context, cancellationToken);
        if (!stopped.IsSuccess) return false;

        session.TransitionTo(MeetingState.Ended, "Meeting session ended.");
        _sessionCoordinator.TryUpdateStatus(session.SessionId, SessionStatus.Completed, out _);
        ConsoleLogger.Info($"[SESSION] Ended: {session.SessionId}");
        return true;
    }

    private MeetingSession Fail(MeetingSession session, string reason)
    {
        session.Fail(reason);
        if (session.Allocation != null)
            _sessionCoordinator.TryUpdateStatus(session.SessionId, SessionStatus.Failed, out _);
        ConsoleLogger.Error($"[SESSION] Failed: {reason}");
        return session;
    }
}
