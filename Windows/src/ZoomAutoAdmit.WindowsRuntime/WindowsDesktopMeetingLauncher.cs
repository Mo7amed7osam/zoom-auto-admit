using ZoomAutoAdmit.Core.Engines;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.Core.Sessions;

namespace ZoomAutoAdmit.WindowsRuntime;

public interface IWindowsDesktopMeetingPlatform
{
    Task<MeetingOperationResult> SwitchAccountAsync(
        MeetingAccount account,
        CancellationToken cancellationToken);
    Task<MeetingOperationResult> LaunchMeetingAsync(Uri meetingUrl, CancellationToken cancellationToken);
    Task<MeetingOperationResult> VerifyJoinedAsync(CancellationToken cancellationToken);
    Task<MeetingOperationResult> DisableMicrophoneAsync(CancellationToken cancellationToken);
    Task<MeetingOperationResult> DisableCameraAsync(CancellationToken cancellationToken);
    Task<MeetingOperationResult> StopAsync(CancellationToken cancellationToken);
}

public sealed class WindowsDesktopMeetingLauncher : IMeetingEngineRuntime, IAsyncDisposable
{
    private readonly IAutoAdmitEngine _autoAdmitEngine;
    private readonly IWindowsDesktopMeetingPlatform _platform;
    private readonly object _monitorSync = new();
    private CancellationTokenSource? _monitorCancellation;
    private Task<int>? _monitorTask;

    public WindowsDesktopMeetingLauncher(
        IAutoAdmitEngine autoAdmitEngine,
        IWindowsDesktopMeetingPlatform platform)
    {
        _autoAdmitEngine = autoAdmitEngine ?? throw new ArgumentNullException(nameof(autoAdmitEngine));
        _platform = platform ?? throw new ArgumentNullException(nameof(platform));
        if (!_autoAdmitEngine.Name.Equals("windows", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("The Desktop launcher requires the Windows Auto Admit engine.", nameof(autoAdmitEngine));
    }

    public SessionEngineType EngineType => SessionEngineType.Desktop;

    public Task<MeetingOperationResult> SwitchAccountAsync(
        MeetingAccount account,
        CancellationToken cancellationToken = default) =>
        SafeAsync(() => _platform.SwitchAccountAsync(account, cancellationToken));

    public Task<MeetingOperationResult> LaunchAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default) =>
        SafeAsync(() => _platform.LaunchMeetingAsync(context.Session.MeetingUrl, cancellationToken));

    public Task<MeetingOperationResult> VerifyJoinedAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default) =>
        SafeAsync(() => _platform.VerifyJoinedAsync(cancellationToken));

    public Task<MeetingOperationResult> DisableMicrophoneAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default) =>
        SafeAsync(() => _platform.DisableMicrophoneAsync(cancellationToken));

    public Task<MeetingOperationResult> DisableCameraAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default) =>
        SafeAsync(() => _platform.DisableCameraAsync(cancellationToken));

    public async Task<MeetingOperationResult> StartAutoAdmitAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default)
    {
        lock (_monitorSync)
        {
            if (_monitorTask is { IsCompleted: false })
                return MeetingOperationResult.Success();
            var monitorCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _monitorCancellation = monitorCancellation;
            var options = new CliOptions
            {
                Command = "waiting-room-auto-admit",
                CommandExplicitlySet = true,
                Engine = "windows",
                TimeoutSeconds = 0,
                TimeoutExplicitlySet = false
            };
            _monitorTask = Task.Run(
                () => _autoAdmitEngine.RunAsync(options, monitorCancellation.Token),
                CancellationToken.None);
        }

        var completed = await Task.WhenAny(
            _monitorTask,
            Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken));
        if (!ReferenceEquals(completed, _monitorTask)) return MeetingOperationResult.Success();
        int exitCode = await _monitorTask;
        return MeetingOperationResult.Failure(
            $"Windows Auto Admit stopped during startup with exit code {exitCode}.");
    }

    public async Task<MeetingOperationResult> StopAutoAdmitAsync(
        MeetingLaunchContext context,
        CancellationToken cancellationToken = default)
    {
        Cancel();
        var platformResult = await SafeAsync(() => _platform.StopAsync(cancellationToken));
        Task<int>? monitorTask;
        lock (_monitorSync) monitorTask = _monitorTask;
        if (monitorTask is { IsCompleted: false })
        {
            var completed = await Task.WhenAny(
                monitorTask,
                Task.Delay(TimeSpan.FromSeconds(5), cancellationToken));
            if (!ReferenceEquals(completed, monitorTask))
                return MeetingOperationResult.Failure("Windows Auto Admit did not stop within five seconds.");
        }
        return platformResult;
    }

    public void Cancel()
    {
        lock (_monitorSync) _monitorCancellation?.Cancel();
    }

    public async ValueTask DisposeAsync()
    {
        Cancel();
        Task<int>? monitorTask;
        lock (_monitorSync)
        {
            monitorTask = _monitorTask;
            _monitorTask = null;
            _monitorCancellation?.Dispose();
            _monitorCancellation = null;
        }
        if (monitorTask != null)
        {
            try { await monitorTask; }
            catch (OperationCanceledException) { }
        }
    }

    private static async Task<MeetingOperationResult> SafeAsync(
        Func<Task<MeetingOperationResult>> operation)
    {
        try { return await operation(); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return MeetingOperationResult.Failure(ex.Message); }
    }
}
