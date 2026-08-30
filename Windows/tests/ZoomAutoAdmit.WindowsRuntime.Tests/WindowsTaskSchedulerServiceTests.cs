using ZoomAutoAdmit.WindowsRuntime.Scheduling;
using Xunit;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsTaskSchedulerServiceTests : IDisposable
{
    private readonly string _testLogPath = Path.Combine(
        Path.GetTempPath(),
        $"test_scheduler_{Guid.NewGuid():N}.log");

    public WindowsTaskSchedulerServiceTests()
    {
        WindowsSchedulerLog.FilePath = _testLogPath;
    }

    [Fact]
    public void TaskNameIsFormattedCorrectly()
    {
        var id = Guid.Parse("12345678-1234-1234-1234-123456789abc");
        string taskName = WindowsTaskSchedulerService.GetTaskName(id);

        Assert.Equal(@"ZoomAutoAdmit\Schedule_12345678123412341234123456789abc", taskName);
    }

    [Fact]
    public void BuildTaskRunCommandContainsRequiredArguments()
    {
        var service = new WindowsTaskSchedulerService("C:\\FakePath\\ZoomAutoAdmit.Inspector.exe");
        var schedule = new MeetingSchedule(
            Guid.NewGuid(),
            "Daily Standup",
            "https://zoom.us/j/9876543210",
            "teacher-account-1",
            new TimeOnly(14, 30),
            ScheduleDays.EveryDay,
            true);

        string command = service.BuildTaskRunCommand(schedule);

        Assert.Contains("meeting-start", command);
        Assert.Contains("--account-id \"teacher-account-1\"", command);
        Assert.Contains("--meeting-url \"https://zoom.us/j/9876543210\"", command);
        Assert.Contains($"--schedule-id {schedule.Id}", command);
    }

    [Fact]
    public async Task LiveTaskSchedulerCreatesAndDeletesRealWindowsTask()
    {
        var service = new WindowsTaskSchedulerService();
        var schedule = new MeetingSchedule(
            Guid.NewGuid(),
            "Live Test Task",
            "https://zoom.us/j/91310623669",
            "CAI5_AIS4_S7",
            new TimeOnly(23, 59),
            ScheduleDays.EveryDay,
            true);

        // Register task
        await service.RegisterTaskAsync(schedule);

        string taskName = WindowsTaskSchedulerService.GetTaskName(schedule.Id);

        // Verify task exists in Windows Task Scheduler
        var psi = new System.Diagnostics.ProcessStartInfo("schtasks.exe")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        psi.ArgumentList.Add("/Query");
        psi.ArgumentList.Add("/TN");
        psi.ArgumentList.Add(taskName);
        psi.ArgumentList.Add("/FO");
        psi.ArgumentList.Add("LIST");

        using var queryProc = System.Diagnostics.Process.Start(psi)!;
        string queryOutput = await queryProc.StandardOutput.ReadToEndAsync();
        string queryError = await queryProc.StandardError.ReadToEndAsync();
        await queryProc.WaitForExitAsync();

        string logFile = File.Exists(_testLogPath) ? File.ReadAllText(_testLogPath) : "NO LOG FILE";

        Assert.True(queryProc.ExitCode == 0, $"Query failed with exit code {queryProc.ExitCode}. Output: '{queryOutput}', Error: '{queryError}', Log: '{logFile}'");
        Assert.Contains(taskName, queryOutput);

        // Delete task
        await service.DeleteTaskAsync(schedule.Id);

        // Verify task is gone
        using var queryProc2 = System.Diagnostics.Process.Start(psi)!;
        await queryProc2.WaitForExitAsync();
        Assert.NotEqual(0, queryProc2.ExitCode);
    }

    [Fact]
    public async Task ScheduleStoreNotifiesTaskSchedulerOnUpsertAndDelete()
    {
        var fakeScheduler = new FakeTaskScheduler();
        string storePath = Path.Combine(Path.GetTempPath(), $"sched_store_{Guid.NewGuid():N}.json");
        var store = new WindowsMeetingScheduleStore(storePath, fakeScheduler);

        var schedule = new MeetingSchedule(
            Guid.NewGuid(),
            "Test Meeting",
            "https://zoom.us/j/123456789",
            "acc1",
            new TimeOnly(10, 0),
            ScheduleDays.Monday | ScheduleDays.Wednesday,
            true);

        await store.UpsertAsync(schedule);
        Assert.Single(fakeScheduler.RegisteredSchedules);
        Assert.Equal(schedule.Id, fakeScheduler.RegisteredSchedules[0].Id);

        // Updating only LastTriggeredDate should not re-trigger task scheduler registration
        await store.UpsertAsync(schedule with { LastTriggeredDate = DateOnly.FromDateTime(DateTime.Now) });
        Assert.Single(fakeScheduler.RegisteredSchedules);

        await store.DeleteAsync(schedule.Id);
        Assert.Single(fakeScheduler.DeletedScheduleIds);
        Assert.Equal(schedule.Id, fakeScheduler.DeletedScheduleIds[0]);

        if (File.Exists(storePath)) File.Delete(storePath);
    }

    public void Dispose()
    {
        if (File.Exists(_testLogPath))
        {
            try { File.Delete(_testLogPath); } catch { }
        }
    }

    private sealed class FakeTaskScheduler : IWindowsTaskScheduler
    {
        public List<MeetingSchedule> RegisteredSchedules { get; } = [];
        public List<Guid> DeletedScheduleIds { get; } = [];

        public Task RegisterTaskAsync(MeetingSchedule schedule, CancellationToken cancellationToken = default)
        {
            RegisteredSchedules.Add(schedule);
            return Task.CompletedTask;
        }

        public Task DeleteTaskAsync(Guid scheduleId, CancellationToken cancellationToken = default)
        {
            DeletedScheduleIds.Add(scheduleId);
            return Task.CompletedTask;
        }
    }
}
