using System.Diagnostics;

namespace ZoomAutoAdmit.WindowsRuntime.Scheduling;

public sealed class WindowsTaskSchedulerService : IWindowsTaskScheduler
{
    private readonly string? _customExecutablePath;

    public WindowsTaskSchedulerService(string? customExecutablePath = null)
    {
        _customExecutablePath = customExecutablePath;
    }

    public static string GetTaskName(Guid scheduleId) => $@"ZoomAutoAdmit\Schedule_{scheduleId:N}";

    public static string GetLauncherScriptPath(Guid scheduleId) =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ZoomAutoAdmit",
            "Schedules",
            $"launch_{scheduleId:N}.cmd");

    public async Task RegisterTaskAsync(MeetingSchedule schedule, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(schedule);
        string taskName = GetTaskName(schedule.Id);

        if (!schedule.Enabled)
        {
            await DeleteTaskAsync(schedule.Id, cancellationToken);
            return;
        }

        try
        {
            string timeString = schedule.Time.ToString("HH:mm");
            string exePath = ResolveInspectorExecutablePath();
            string launcherPath = GetLauncherScriptPath(schedule.Id);
            string launcherDir = Path.GetDirectoryName(launcherPath)!;
            Directory.CreateDirectory(launcherDir);

            string scriptContent = exePath.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)
                ? $"@echo off\r\ndotnet \"{exePath}\" meeting-start --schedule-id {schedule.Id}\r\n"
                : $"@echo off\r\n\"{exePath}\" meeting-start --schedule-id {schedule.Id}\r\n";

            await File.WriteAllTextAsync(launcherPath, scriptContent, System.Text.Encoding.UTF8, cancellationToken);

            string schedulePart;
            if ((schedule.Days & ScheduleDays.EveryDay) == ScheduleDays.EveryDay)
            {
                schedulePart = $"/SC DAILY /ST {timeString}";
            }
            else
            {
                var daysList = new List<string>();
                if (schedule.Days.HasFlag(ScheduleDays.Monday)) daysList.Add("MON");
                if (schedule.Days.HasFlag(ScheduleDays.Tuesday)) daysList.Add("TUE");
                if (schedule.Days.HasFlag(ScheduleDays.Wednesday)) daysList.Add("WED");
                if (schedule.Days.HasFlag(ScheduleDays.Thursday)) daysList.Add("THU");
                if (schedule.Days.HasFlag(ScheduleDays.Friday)) daysList.Add("FRI");
                if (schedule.Days.HasFlag(ScheduleDays.Saturday)) daysList.Add("SAT");
                if (schedule.Days.HasFlag(ScheduleDays.Sunday)) daysList.Add("SUN");

                if (daysList.Count == 0) daysList.Add("MON");

                schedulePart = $"/SC WEEKLY /D {string.Join(",", daysList)} /ST {timeString}";
            }

            string commandLine = $"/Create /TN \"{taskName}\" /TR \"\\\"{launcherPath}\\\"\" {schedulePart} /F";

            var (exitCode, stdout, stderr) = await RunSchtasksAsync(commandLine, cancellationToken);
            if (exitCode == 0)
            {
                WindowsSchedulerLog.Write(
                    "SCHEDULE_REGISTERED",
                    $"Task: {taskName}, Name: '{schedule.Name}', Time: {timeString}, Days: {schedule.Days}, Account: {schedule.AccountId}, Url: {schedule.MeetingUrl}");
            }
            else
            {
                string error = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
                WindowsSchedulerLog.Write("ERROR", $"Failed to register Windows Scheduled Task '{taskName}': {error.Trim()}");
            }
        }
        catch (Exception ex)
        {
            WindowsSchedulerLog.Write("ERROR", $"Exception while registering task '{taskName}': {ex.Message}");
        }
    }

    public async Task DeleteTaskAsync(Guid scheduleId, CancellationToken cancellationToken = default)
    {
        string taskName = GetTaskName(scheduleId);
        string launcherPath = GetLauncherScriptPath(scheduleId);
        if (File.Exists(launcherPath))
        {
            try { File.Delete(launcherPath); } catch { }
        }

        try
        {
            string commandLine = $"/Delete /TN \"{taskName}\" /F";
            var (exitCode, stdout, stderr) = await RunSchtasksAsync(commandLine, cancellationToken);
            if (exitCode != 0 && !stdout.Contains("ERROR: The system cannot find the file specified", StringComparison.OrdinalIgnoreCase)
                             && !stderr.Contains("ERROR: The system cannot find the file specified", StringComparison.OrdinalIgnoreCase))
            {
                string error = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
                WindowsSchedulerLog.Write("ERROR", $"Failed to delete Windows Scheduled Task '{taskName}': {error.Trim()}");
            }
        }
        catch (Exception ex)
        {
            WindowsSchedulerLog.Write("ERROR", $"Exception while deleting task '{taskName}': {ex.Message}");
        }
    }

    public string BuildTaskRunCommand(MeetingSchedule schedule)
    {
        string exePath = ResolveInspectorExecutablePath();
        if (exePath.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            return $"dotnet \"{exePath}\" meeting-start --account-id \"{schedule.AccountId}\" --meeting-url \"{schedule.MeetingUrl}\" --schedule-id {schedule.Id}";
        }

        return $"\"{exePath}\" meeting-start --account-id \"{schedule.AccountId}\" --meeting-url \"{schedule.MeetingUrl}\" --schedule-id {schedule.Id}";
    }

    public string ResolveInspectorExecutablePath()
    {
        if (!string.IsNullOrEmpty(_customExecutablePath) && File.Exists(_customExecutablePath))
        {
            return Path.GetFullPath(_customExecutablePath);
        }

        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string exeInBase = Path.Combine(baseDir, "ZoomAutoAdmit.Inspector.exe");
        if (File.Exists(exeInBase)) return Path.GetFullPath(exeInBase);

        string dllInBase = Path.Combine(baseDir, "ZoomAutoAdmit.Inspector.dll");
        if (File.Exists(dllInBase)) return Path.GetFullPath(dllInBase);

        string[] candidatePaths =
        [
            Path.Combine(baseDir, "..", "..", "..", "..", "ZoomAutoAdmit.Inspector", "bin", "Debug", "net8.0-windows10.0.19041.0", "ZoomAutoAdmit.Inspector.exe"),
            Path.Combine(baseDir, "..", "..", "..", "..", "ZoomAutoAdmit.Inspector", "bin", "Release", "net8.0-windows10.0.19041.0", "ZoomAutoAdmit.Inspector.exe"),
            Path.Combine(baseDir, "..", "..", "..", "..", "src", "ZoomAutoAdmit.Inspector", "bin", "Debug", "net8.0-windows10.0.19041.0", "ZoomAutoAdmit.Inspector.exe"),
            Path.Combine(baseDir, "..", "..", "..", "src", "ZoomAutoAdmit.Inspector", "bin", "Debug", "net8.0-windows10.0.19041.0", "ZoomAutoAdmit.Inspector.exe")
        ];

        foreach (var candidate in candidatePaths)
        {
            try
            {
                string fullPath = Path.GetFullPath(candidate);
                if (File.Exists(fullPath)) return fullPath;
            }
            catch { }
        }

        if (Environment.ProcessPath is { } currentProc && currentProc.EndsWith("ZoomAutoAdmit.Inspector.exe", StringComparison.OrdinalIgnoreCase))
        {
            return currentProc;
        }

        return Path.GetFullPath(exeInBase);
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr)> RunSchtasksAsync(
        string commandLine,
        CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo("schtasks.exe", commandLine)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = psi };
        process.Start();

        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);

        await process.WaitForExitAsync(cancellationToken);
        string stdout = await stdoutTask;
        string stderr = await stderrTask;

        return (process.ExitCode, stdout, stderr);
    }
}
