using Microsoft.Playwright;
using ZoomAutoAdmit.Core.Engines;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.WebAutomation.Browser;
using ZoomAutoAdmit.WebAutomation.Models;

namespace ZoomAutoAdmit.WebAutomation;

public sealed class WebAutoAdmitEngine : IAutoAdmitEngine, IAsyncDisposable
{
    private const int MaximumClickAttempts = 2;
    private static readonly TimeSpan VerificationWindow = TimeSpan.FromSeconds(12);
    private static readonly TimeSpan InitialVerificationStabilization = TimeSpan.FromSeconds(1);
    private readonly ZoomProfileManager _profileManager;
    private readonly IZoomBrowserLauncher _browserLauncher;
    private readonly ZoomWebMeetingController _meetingController;
    private readonly ZoomWaitingRoomDom _dom;
    private ZoomBrowserSession? _session;
    private CancellationTokenSource? _stopCancellation;
    private int _stopped;

    public WebAutoAdmitEngine(
        ZoomProfileManager? profileManager = null,
        IZoomBrowserLauncher? browserLauncher = null,
        ZoomWebMeetingController? meetingController = null,
        ZoomWaitingRoomDom? dom = null)
    {
        _profileManager = profileManager ?? new ZoomProfileManager();
        _browserLauncher = browserLauncher ?? new ZoomBrowserLauncher();
        _meetingController = meetingController ?? new ZoomWebMeetingController();
        _dom = dom ?? new ZoomWaitingRoomDom();
    }

    public string Name => "web";

    public async Task<int> RunAsync(CliOptions options, CancellationToken cancellationToken = default)
    {
        int timeoutSeconds = options.TimeoutExplicitlySet ? options.TimeoutSeconds : 0;
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeoutSeconds > 0) linkedCancellation.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            linkedCancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;

        try
        {
            await StartAsync(options, linkedCancellation.Token);
            await MonitorAsync(options, linkedCancellation.Token);
            return 0;
        }
        catch (OperationCanceledException) when (linkedCancellation.IsCancellationRequested)
        {
            return 0;
        }
        catch (PlaywrightException ex)
        {
            ConsoleLogger.Error($"WEB_BROWSER_FAILURE: {ex.Message}");
            return 1;
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"WEB_AUTO_ADMIT_FAILURE: {ex.Message}");
            return 1;
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
            await StopAsync();
        }
    }

    public async Task StartAsync(CliOptions options, CancellationToken cancellationToken = default)
    {
        if (_session != null) throw new InvalidOperationException("Web auto-admit engine is already started.");
        if (string.IsNullOrWhiteSpace(options.MeetingUrl))
            throw new ArgumentException("The web engine requires --meeting-url <Zoom URL>.", nameof(options));
        _ = ZoomWebMeetingController.ValidateMeetingUrl(options.MeetingUrl);

        Interlocked.Exchange(ref _stopped, 0);
        _stopCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var profile = _profileManager.GetOrCreate(options.WebProfile);
        ConsoleLogger.Success("WEB_PROFILE_LOADED");
        ConsoleLogger.Info($"Profile: {profile.Name}");
        var plan = _profileManager.CreateLaunchPlan(profile, options.WebHeaded);
        _session = await _browserLauncher.LaunchAsync(plan, _stopCancellation.Token);
        ConsoleLogger.Success("WEB_BROWSER_STARTED");
        ConsoleLogger.Info($"Browser mode: {(_session.IsHeadless ? "headless" : "visible")}");
        await _meetingController.OpenAndWaitForHostControlsAsync(
            _session,
            options.MeetingUrl,
            _profileManager,
            _stopCancellation.Token);
        ConsoleLogger.Success("Waiting room monitor started");
    }

    public async Task MonitorAsync(CliOptions options, CancellationToken cancellationToken = default)
    {
        var session = _session ?? throw new InvalidOperationException("StartAsync must complete before MonitorAsync.");
        if (string.IsNullOrWhiteSpace(options.MeetingUrl))
            throw new ArgumentException("The web engine requires --meeting-url <Zoom URL>.", nameof(options));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _stopCancellation?.Token ?? CancellationToken.None);
        bool pageMissingLogged = false;

        while (!linked.IsCancellationRequested)
        {
            try
            {
                var surface = await _meetingController.FindActiveMeetingAsync(session);
                if (surface == null)
                {
                    if (ZoomWebMeetingController.HasOpenMeetingPage(session))
                    {
                        await DelayAsync(options.WebPollIntervalMilliseconds, linked.Token);
                        continue;
                    }
                    if (!pageMissingLogged)
                    {
                        ConsoleLogger.Info("WEB_MEETING_PAGE_NOT_FOUND");
                        pageMissingLogged = true;
                    }
                    await _meetingController.KeepMeetingPageAliveAsync(session, options.MeetingUrl);
                    await DelayAsync(options.WebPollIntervalMilliseconds, linked.Token);
                    continue;
                }

                pageMissingLogged = false;
                var snapshot = await _dom.CaptureAsync(surface);
                var decision = WebAdmissionPolicy.Decide(snapshot);
                if (decision.Kind == WebAdmissionKind.None)
                {
                    await DelayAsync(options.WebPollIntervalMilliseconds, linked.Token);
                    continue;
                }

                ConsoleLogger.Info("WEB_WAITING_ROOM_DETECTED");
                ConsoleLogger.Info($"Waiting participants: {snapshot.WaitingCount}");
                await ExecuteWithRetryAsync(
                    session,
                    snapshot,
                    decision,
                    options.WebPollIntervalMilliseconds,
                    linked.Token);
            }
            catch (PlaywrightException ex) when (PlaywrightNavigationFailurePolicy.IsTransient(ex))
            {
                ConsoleLogger.Warn($"WEB_DOM_RETRY: {ex.Message}");
            }

            await DelayAsync(options.WebPollIntervalMilliseconds, linked.Token);
        }
    }

    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref _stopped, 1) != 0) return;
        _stopCancellation?.Cancel();
        _stopCancellation?.Dispose();
        _stopCancellation = null;
        if (_session != null)
        {
            await _session.DisposeAsync();
            _session = null;
        }
        ConsoleLogger.Info("WEB_AUTO_ADMIT_STOPPED");
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    private async Task ExecuteWithRetryAsync(
        ZoomBrowserSession session,
        WebWaitingRoomSnapshot initialSnapshot,
        WebAdmissionDecision initialDecision,
        int pollMilliseconds,
        CancellationToken cancellationToken)
    {
        var before = initialSnapshot;
        var decision = initialDecision;
        var singleAdmitStrategy = AdmitStrategy.NotificationThenParticipantRow;
        for (int attempt = 1; attempt <= MaximumClickAttempts; attempt++)
        {
            var surface = await _meetingController.FindActiveMeetingAsync(session);
            if (surface == null) return;

            bool clicked;
            if (decision.Kind == WebAdmissionKind.AdmitAll)
            {
                ConsoleLogger.Info("WEB_ADMIT_ALL_FOUND");
                clicked = await _dom.ClickAdmitAllAsync(surface);
            }
            else if (decision.Kind == WebAdmissionKind.Single && decision.Participant != null)
            {
                ConsoleLogger.Info("WEB_ADMIT_FOUND");
                ConsoleLogger.Info($"Participant: {decision.Participant.Name}");
                clicked = await _dom.ClickParticipantAsync(
                    surface,
                    decision.Participant.Identity,
                    singleAdmitStrategy);
            }
            else
            {
                return;
            }

            if (!clicked)
            {
                ConsoleLogger.Warn("WEB_ADMIT_TARGET_DISAPPEARED_BEFORE_CLICK");
                return;
            }
            ConsoleLogger.Success("WEB_CLICK_SENT");

            var verification = await VerifyAsync(
                session,
                before,
                decision,
                pollMilliseconds,
                cancellationToken);
            if (verification.Result.IsVerified)
            {
                ConsoleLogger.Success("WEB_ADMISSION_VERIFIED");
                ConsoleLogger.Success("ADMISSION_CONFIRMED");
                return;
            }

            ConsoleLogger.Warn($"WEB_ADMISSION_NOT_VERIFIED: {verification.Result.Reason}");
            if (attempt >= MaximumClickAttempts || !verification.Result.ShouldRetry) return;
            before = verification.Snapshot;
            decision = WebAdmissionPolicy.Decide(before);
            if (decision.Kind == WebAdmissionKind.None) return;
            singleAdmitStrategy = AdmitStrategy.ParticipantRowOnly;
            ConsoleLogger.Info("WEB_ADMISSION_RETRY");
        }
    }

    private async Task<(WebAdmissionVerification Result, WebWaitingRoomSnapshot Snapshot)> VerifyAsync(
        ZoomBrowserSession session,
        WebWaitingRoomSnapshot before,
        WebAdmissionDecision decision,
        int pollMilliseconds,
        CancellationToken cancellationToken)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + VerificationWindow;
        var latest = before;
        var result = new WebAdmissionVerification(false, true, "Waiting for the Waiting Room DOM to update.");
        await Task.Delay(InitialVerificationStabilization, cancellationToken);
        while (DateTimeOffset.UtcNow < deadline)
        {
            await DelayAsync(pollMilliseconds, cancellationToken);
            try
            {
                var surface = await _meetingController.FindActiveMeetingAsync(session);
                if (surface == null)
                {
                    result = new(
                        false,
                        true,
                        "Waiting for the meeting page to finish updating.");
                    ConsoleLogger.Info($"ADMISSION_VERIFICATION_RETRY: {result.Reason}");
                    continue;
                }

                latest = await _dom.CaptureAsync(surface);
                result = WebAdmissionVerifier.Evaluate(before, latest, decision);
                if (result.IsVerified || !result.ShouldRetry) return (result, latest);
                ConsoleLogger.Info($"ADMISSION_VERIFICATION_RETRY: {result.Reason}");
            }
            catch (PlaywrightException ex) when (PlaywrightNavigationFailurePolicy.IsTransient(ex))
            {
                result = new(
                    false,
                    true,
                    "Waiting for the retained meeting frame to reconnect.");
                ConsoleLogger.Info($"ADMISSION_VERIFICATION_RETRY: {result.Reason}");
            }
        }
        return (result, latest);
    }

    private static Task DelayAsync(int milliseconds, CancellationToken cancellationToken) =>
        Task.Delay(TimeSpan.FromMilliseconds(Math.Clamp(milliseconds, 500, 1000)), cancellationToken);
}
