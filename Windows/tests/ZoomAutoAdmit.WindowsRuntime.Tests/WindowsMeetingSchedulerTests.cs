using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.WindowsRuntime.Scheduling;
using Xunit;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsMeetingSchedulerTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "ZoomAutoAdmitSchedulerTests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task CreateSchedulePersistsAllFields()
    {
        var store = Store();
        var schedule = Schedule(enabled: true);

        await store.UpsertAsync(schedule);

        Assert.Equal(schedule, Assert.Single(await store.ListAsync()));
    }

    [Fact]
    public async Task DeleteScheduleRemovesIt()
    {
        var store = Store();
        var schedule = Schedule(enabled: true);
        await store.UpsertAsync(schedule);

        Assert.True(await store.DeleteAsync(schedule.Id));
        Assert.Empty(await store.ListAsync());
    }

    [Fact]
    public async Task DueScheduleTriggersExistingMeetingRunnerOnce()
    {
        DateTimeOffset now = DateTimeOffset.Now;
        var store = Store();
        await store.UpsertAsync(Schedule(
            enabled: true,
            days: Day(now.DayOfWeek),
            time: new TimeOnly(now.Hour, now.Minute)));
        var runner = new FakeScheduledMeetingRunner();
        await using var scheduler = new WindowsMeetingScheduler(store, runner);

        int first = await scheduler.RunDueAsync(now);
        int second = await scheduler.RunDueAsync(now.AddSeconds(10));

        Assert.Equal(1, first);
        Assert.Equal(0, second);
        Assert.Single(runner.Meetings);
        Assert.Equal("teacher-1", runner.Meetings[0].AccountId);
    }

    [Fact]
    public async Task DisabledScheduleIsIgnored()
    {
        DateTimeOffset now = DateTimeOffset.Now;
        var store = Store();
        await store.UpsertAsync(Schedule(
            enabled: false,
            days: Day(now.DayOfWeek),
            time: new TimeOnly(now.Hour, now.Minute)));
        var runner = new FakeScheduledMeetingRunner();
        await using var scheduler = new WindowsMeetingScheduler(store, runner);

        int triggered = await scheduler.RunDueAsync(now);

        Assert.Equal(0, triggered);
        Assert.Empty(runner.Meetings);
    }

    private WindowsMeetingScheduleStore Store() =>
        new(Path.Combine(_root, "Schedules", "schedules.json"));

    private static MeetingSchedule Schedule(
        bool enabled,
        ScheduleDays days = ScheduleDays.Monday,
        TimeOnly? time = null) =>
        new(
            Guid.NewGuid(),
            "Morning class",
            "https://zoom.us/j/123456789",
            "teacher-1",
            time ?? new TimeOnly(9, 0),
            days,
            enabled);

    private static ScheduleDays Day(DayOfWeek day) => day switch
    {
        DayOfWeek.Monday => ScheduleDays.Monday,
        DayOfWeek.Tuesday => ScheduleDays.Tuesday,
        DayOfWeek.Wednesday => ScheduleDays.Wednesday,
        DayOfWeek.Thursday => ScheduleDays.Thursday,
        DayOfWeek.Friday => ScheduleDays.Friday,
        DayOfWeek.Saturday => ScheduleDays.Saturday,
        _ => ScheduleDays.Sunday
    };

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private sealed class FakeScheduledMeetingRunner : IScheduledMeetingRunner
    {
        public List<ScheduledMeeting> Meetings { get; } = [];

        public Task<MeetingSession> RunAsync(
            ScheduledMeeting meeting,
            CancellationToken cancellationToken = default)
        {
            Meetings.Add(meeting);
            return Task.FromResult(new MeetingSession(
                Guid.NewGuid(),
                meeting,
                DateTimeOffset.UtcNow));
        }
    }
}
