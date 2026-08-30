namespace ZoomAutoAdmit.WindowsRuntime.Scheduling;

public interface IWindowsTaskScheduler
{
    Task RegisterTaskAsync(MeetingSchedule schedule, CancellationToken cancellationToken = default);
    Task DeleteTaskAsync(Guid scheduleId, CancellationToken cancellationToken = default);
}
