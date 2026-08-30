using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Meetings;

namespace ZoomAutoAdmit.WindowsRuntime.Scheduling;

public interface IScheduledMeetingRunner
{
    Task<MeetingSession> RunAsync(ScheduledMeeting meeting, CancellationToken cancellationToken = default);
}

public sealed class OrchestratedScheduledMeetingRunner(MeetingOrchestrator orchestrator)
    : IScheduledMeetingRunner
{
    public Task<MeetingSession> RunAsync(
        ScheduledMeeting meeting,
        CancellationToken cancellationToken = default) =>
        orchestrator.RunAsync(meeting, cancellationToken);
}

public sealed class WindowsMeetingScheduler : IAsyncDisposable
{
    private readonly WindowsMeetingScheduleStore _store;
    private readonly IScheduledMeetingRunner _runner;
    private readonly SemaphoreSlim _triggerLock = new(1, 1);
    private CancellationTokenSource? _cancellation;
    private Task? _loop;

    public WindowsMeetingScheduler(
        WindowsMeetingScheduleStore store,
        IScheduledMeetingRunner runner)
    {
        _store = store;
        _runner = runner;
    }

    public event Action<MeetingSession>? SessionStarted;

    public void Start()
    {
        if (_loop is { IsCompleted: false }) return;
        _cancellation = new CancellationTokenSource();
        _loop = MonitorAsync(_cancellation.Token);
    }

    public async Task<int> RunDueAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await _triggerLock.WaitAsync(cancellationToken);
        try
        {
            int triggered = 0;
            DateOnly localDate = DateOnly.FromDateTime(now.LocalDateTime);
            TimeOnly localTime = TimeOnly.FromDateTime(now.LocalDateTime);
            foreach (var schedule in await _store.ListAsync(cancellationToken))
            {
                if (!schedule.Enabled ||
                    !schedule.Days.Includes(now.LocalDateTime.DayOfWeek) ||
                    schedule.LastTriggeredDate == localDate ||
                    localTime < schedule.Time)
                    continue;

                // Persist the claim before launching so overlapping scheduler ticks cannot
                // create the same meeting twice.
                await _store.UpsertAsync(schedule with { LastTriggeredDate = localDate }, cancellationToken);
                try
                {
                    ConsoleLogger.Info($"[SCHEDULER] Triggering: {schedule.Name}");
                    var session = await _runner.RunAsync(
                        new ScheduledMeeting(
                            new Uri(schedule.MeetingUrl),
                            schedule.AccountId,
                            now),
                        cancellationToken);
                    if (session.State != MeetingState.Failed)
                    {
                        triggered++;
                        SessionStarted?.Invoke(session);
                    }
                    else ConsoleLogger.Error($"[SCHEDULER] Failed: {session.FailureReason}");
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                catch (Exception ex) { ConsoleLogger.Error($"[SCHEDULER] Failed: {ex.Message}"); }
            }
            return triggered;
        }
        finally { _triggerLock.Release(); }
    }

    private async Task MonitorAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        try
        {
            await RunDueAsync(DateTimeOffset.Now, cancellationToken);
            while (await timer.WaitForNextTickAsync(cancellationToken))
                await RunDueAsync(DateTimeOffset.Now, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    public async Task StopAsync()
    {
        _cancellation?.Cancel();
        if (_loop != null)
        {
            try { await _loop; }
            catch (OperationCanceledException) { }
        }
        _cancellation?.Dispose();
        _cancellation = null;
        _loop = null;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _triggerLock.Dispose();
    }
}
