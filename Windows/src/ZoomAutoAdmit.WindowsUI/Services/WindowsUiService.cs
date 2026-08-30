using System.Collections.Concurrent;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Sessions;
using ZoomAutoAdmit.Inspector.Runtime;
using ZoomAutoAdmit.WebAutomation;
using ZoomAutoAdmit.WindowsRuntime;
using ZoomAutoAdmit.WindowsRuntime.Scheduling;
using ZoomAutoAdmit.WindowsUI.Infrastructure;

namespace ZoomAutoAdmit.WindowsUI.Services;

public sealed class WindowsUiService : IWindowsUiService, IAsyncDisposable
{
    private readonly WindowsRuntimeBootstrapper _bootstrapper;
    private readonly ConcurrentDictionary<Guid, MeetingSession> _sessions = new();
    private readonly object _statusSync = new();
    private UiActionStatus _currentStatus = new("Application startup", "Ready", string.Empty, false, DateTimeOffset.Now);

    public WindowsUiService(WindowsRuntimeBootstrapper bootstrapper)
    {
        _bootstrapper = bootstrapper ?? throw new ArgumentNullException(nameof(bootstrapper));
        _bootstrapper.Scheduler.SessionStarted += OnScheduledSessionStarted;
        ConsoleLogger.EntryWritten += OnRuntimeLogEntry;
        _bootstrapper.Scheduler.Start();
    }

    public event Action<UiActionStatus>? StatusChanged;
    public UiActionStatus CurrentStatus { get { lock (_statusSync) return _currentStatus; } }

    public Task<IReadOnlyList<WindowsMeetingAccountMetadata>> GetAccountsAsync(
        CancellationToken cancellationToken = default) =>
        _bootstrapper.AccountManager.ListConfiguredAsync(cancellationToken);

    public Task SaveAccountAsync(
        WindowsMeetingAccountMetadata account,
        CancellationToken cancellationToken = default) =>
        _bootstrapper.AccountManager.UpsertAsync(account, cancellationToken);

    public Task<bool> DeleteAccountAsync(
        string accountId,
        CancellationToken cancellationToken = default) =>
        _bootstrapper.AccountManager.DeleteAsync(accountId, cancellationToken);

    public async Task<UiOperationResult> SwitchAccountAsync(
        string accountId,
        CancellationToken cancellationToken = default)
    {
        ConsoleLogger.Info("[DEBUG_SWITCH] Entered SwitchAccountAsync");
        Report("Switch account", "Switching account...", string.Empty, true);
        try
        {
            var account = await _bootstrapper.AccountManager.LoadAsync(accountId, cancellationToken);
            if (account == null)
                return Fail("Switch account", "Account could not be loaded or its credential reference could not be resolved.");
            string zoomIdentity = account.ZoomEmail ?? WindowsCredentialManagerReferenceResolver.TryGetUsername(account.CredentialReference) ?? "(unresolved)";
            ConsoleLogger.Info($"[DEBUG_SWITCH] Target account object: AccountId='{account.AccountId}', DisplayName='{account.DisplayName}', CredentialReference='{account.CredentialReference}', PreferredEngine='{account.PreferredEngine?.ToString() ?? "Auto"}', ZoomIdentity='{zoomIdentity}'");
            Report("Switch account", $"Switching {account.AccountId} to {zoomIdentity}...", string.Empty, true);
            var runtime = _bootstrapper.RuntimeFactory.Get(SessionEngineType.Desktop);
            var result = await Task.Run(
                () => runtime.SwitchAccountAsync(account, cancellationToken),
                cancellationToken);
            if (!result.IsSuccess)
                return Fail("Switch account", result.ErrorMessage ?? "Zoom Desktop account switching failed.");
            string message = $"{account.AccountId}: Zoom Desktop account verified: {zoomIdentity}.";
            Report("Switch account", message, string.Empty, false);
            return new UiOperationResult(true, message);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return Fail("Switch account", "Account switching was cancelled.");
        }
        catch (Exception ex) { return Fail("Switch account", ex.Message); }
    }

    public async Task<SessionDisplayInfo> StartMeetingAsync(
        string accountId,
        string meetingUrl,
        EnginePreference preference,
        CancellationToken cancellationToken = default)
    {
        Uri url = ZoomWebMeetingController.ValidateMeetingUrl(meetingUrl);
        Report("Start meeting", "Loading account and requesting meeting start...", string.Empty, true);
        SessionEngineType? engine = preference switch
        {
            EnginePreference.Desktop => SessionEngineType.Desktop,
            EnginePreference.Web => SessionEngineType.Web,
            _ => null
        };
        var session = await _bootstrapper.Orchestrator.RunAsync(
            new ScheduledMeeting(url, accountId, DateTimeOffset.UtcNow, PreferredEngine: engine),
            cancellationToken);
        if (session.State == MeetingState.Failed)
        {
            string reason = session.FailureReason ?? "Meeting startup failed.";
            Fail("Start meeting", reason);
            throw new InvalidOperationException(reason);
        }
        _sessions[session.SessionId] = session;
        var display = await ToDisplayInfoAsync(session, cancellationToken);
        Report("Start meeting", $"Meeting started using {display.EngineType}.", string.Empty, false);
        return display;
    }

    public async Task<bool> StopMeetingAsync(
        Guid sessionId,
        CancellationToken cancellationToken = default)
    {
        if (!_sessions.TryGetValue(sessionId, out var session)) return false;
        bool stopped = await _bootstrapper.Orchestrator.EndAsync(session, cancellationToken);
        if (stopped) _sessions.TryRemove(sessionId, out _);
        return stopped;
    }

    public async Task<IReadOnlyList<SessionDisplayInfo>> GetActiveSessionsAsync(
        CancellationToken cancellationToken = default)
    {
        var configuredAccounts = await GetAccountsAsync(cancellationToken);
        var accountNames = configuredAccounts.ToDictionary(
            account => account.AccountId,
            account => account.DisplayName,
            StringComparer.OrdinalIgnoreCase);
        return _bootstrapper.SessionCoordinator.ActiveSessions.Select(active =>
        {
            _sessions.TryGetValue(active.SessionId, out var meeting);
            return new SessionDisplayInfo(
                active.SessionId,
                active.AccountId,
                accountNames.GetValueOrDefault(active.AccountId, active.AccountId),
                active.EngineType,
                meeting?.State.ToString() ?? active.Status.ToString(),
                active.StartTime);
        }).ToArray();
    }

    public Task<IReadOnlyList<MeetingSchedule>> GetSchedulesAsync(
        CancellationToken cancellationToken = default) =>
        _bootstrapper.ScheduleStore.ListAsync(cancellationToken);

    public Task SaveScheduleAsync(
        MeetingSchedule schedule,
        CancellationToken cancellationToken = default) =>
        _bootstrapper.ScheduleStore.UpsertAsync(schedule, cancellationToken);

    public Task<bool> DeleteScheduleAsync(
        Guid scheduleId,
        CancellationToken cancellationToken = default) =>
        _bootstrapper.ScheduleStore.DeleteAsync(scheduleId, cancellationToken);

    private void OnScheduledSessionStarted(MeetingSession session) =>
        CompleteScheduledSession(session);

    private void CompleteScheduledSession(MeetingSession session)
    {
        _sessions[session.SessionId] = session;
        Report("Scheduled meeting", "Meeting started successfully.", string.Empty, false);
    }

    private void OnRuntimeLogEntry(LogEntry entry)
    {
        string message = entry.Message;
        if (message.StartsWith("[KEYBOARD_SWITCH]", StringComparison.Ordinal))
        {
            WindowsUiRuntimeLog.Write("KEYBOARD_SWITCH", message);
            if (CurrentStatus.LastAction == "Switch account" && CurrentStatus.IsBusy)
                Report("Switch account", message["[KEYBOARD_SWITCH]".Length..].Trim(), string.Empty, true);
        }
        if (message.StartsWith("[DEBUG_SWITCH]", StringComparison.Ordinal))
            WindowsUiRuntimeLog.Write("DEBUG_SWITCH", message);
        if (message.StartsWith("[SCHEDULER] Triggering:", StringComparison.Ordinal))
            Report("Scheduled meeting", $"Schedule detected: {message["[SCHEDULER] Triggering:".Length..].Trim()}", string.Empty, true);
        else if (message.StartsWith("[ACCOUNT] Loaded:", StringComparison.Ordinal) && CurrentStatus.LastAction == "Scheduled meeting")
            Report("Scheduled meeting", $"Account loaded: {message["[ACCOUNT] Loaded:".Length..].Trim()}", string.Empty, true);
        else if (message.StartsWith("[SESSION] Created:", StringComparison.Ordinal) && CurrentStatus.LastAction == "Scheduled meeting")
            Report("Scheduled meeting", $"Session created: {message["[SESSION] Created:".Length..].Trim()}", string.Empty, true);
        else if ((message == "[MEETING] Launching" || message == "[MEETING] Joining") && CurrentStatus.LastAction == "Scheduled meeting")
            Report("Scheduled meeting", "Meeting start requested.", string.Empty, true);
        else if ((message.StartsWith("[SCHEDULER] Failed:", StringComparison.Ordinal) ||
                  message.StartsWith("[SESSION] Failed:", StringComparison.Ordinal)) &&
                 CurrentStatus.LastAction == "Scheduled meeting")
            Fail("Scheduled meeting", message[(message.IndexOf(':') + 1)..].Trim());
        else if (message.StartsWith("[ACCOUNT_SWITCH]", StringComparison.Ordinal) && CurrentStatus.LastAction == "Switch account")
        {
            if (message.Contains("Opening profile menu", StringComparison.OrdinalIgnoreCase))
                Report("Switch account", "Opening Zoom profile menu...", string.Empty, true);
            else if (message.Contains("Selecting account", StringComparison.OrdinalIgnoreCase))
                Report("Switch account", "Selecting account...", string.Empty, true);
        }
    }

    private UiOperationResult Fail(string action, string error)
    {
        Report(action, "Failed", error, false);
        return new UiOperationResult(false, error);
    }

    private void Report(string action, string operation, string error, bool isBusy)
    {
        var status = new UiActionStatus(action, operation, error, isBusy, DateTimeOffset.Now);
        lock (_statusSync) _currentStatus = status;
        WindowsUiRuntimeLog.Write("ACTION", $"{action} | {operation} | {error}");
        StatusChanged?.Invoke(status);
    }

    private async Task<SessionDisplayInfo> ToDisplayInfoAsync(
        MeetingSession session,
        CancellationToken cancellationToken)
    {
        var account = (await GetAccountsAsync(cancellationToken)).FirstOrDefault(candidate =>
            candidate.AccountId.Equals(session.AccountId, StringComparison.OrdinalIgnoreCase));
        return new SessionDisplayInfo(
            session.SessionId,
            session.AccountId,
            account?.DisplayName ?? session.AccountId,
            session.Allocation!.EngineType,
            session.State.ToString(),
            session.StartTime);
    }

    public async ValueTask DisposeAsync()
    {
        _bootstrapper.Scheduler.SessionStarted -= OnScheduledSessionStarted;
        ConsoleLogger.EntryWritten -= OnRuntimeLogEntry;
        await _bootstrapper.Scheduler.StopAsync();
        foreach (var sessionId in _sessions.Keys.ToArray())
        {
            try { await StopMeetingAsync(sessionId); }
            catch { }
        }
        await _bootstrapper.DisposeAsync();
    }
}
