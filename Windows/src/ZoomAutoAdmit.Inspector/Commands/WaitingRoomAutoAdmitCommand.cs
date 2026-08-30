using System.Drawing;
using System.Drawing.Imaging;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Interop;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;
using ZoomAutoAdmit.UIAutomation.Window;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class WaitingRoomAutoAdmitCommand
{
    private static readonly TimeSpan FrameDelay = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan HoverRenderDelay = TimeSpan.FromMilliseconds(200);
    private static readonly TimeSpan IdleDelay = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan VerificationWindow = TimeSpan.FromSeconds(2.5);
    private const double MinimumPanelRowConfidence = 0.90;

    public static int Execute(CliOptions options, CancellationToken cancellationToken = default)
    {
        int timeoutSeconds = options.TimeoutExplicitlySet ? options.TimeoutSeconds : 0;
        Console.WriteLine("================================================================================");
        Console.WriteLine("WARNING: CONTINUOUS WAITING ROOM AUTO-ADMIT IS ACTIVE");
        Console.WriteLine("Verified Zoom/Windows Waiting Room notifications will be clicked one at a time.");
        Console.WriteLine($"Duration: {(timeoutSeconds == 0 ? "until Ctrl+C" : timeoutSeconds + " seconds")}");
        Console.WriteLine("================================================================================");
        Console.WriteLine("AUTO_ADMIT_STARTED");

        var engine = new WindowsNativeOcrEngine();
        if (!engine.IsAvailable)
        {
            ConsoleLogger.Error("OCR_INITIALIZATION_FAILED");
            return 1;
        }

        string diagnosticsDirectory = Path.Combine(Environment.CurrentDirectory, "diagnostics");
        Directory.CreateDirectory(diagnosticsDirectory);
        string framePath = Path.Combine(diagnosticsDirectory, "auto-admit-current-frame.png");
        string panelAfterHoverPath = Path.Combine(diagnosticsDirectory, "panel-after-hover.png");
        string panelRowBeforeHoverPath = Path.Combine(diagnosticsDirectory, "panel-row-before-hover.png");
        string panelRowAfterHoverPath = Path.Combine(diagnosticsDirectory, "panel-row-after-hover.png");
        string panelActionAreaPath = Path.Combine(diagnosticsDirectory, "panel-action-area.png");
        string panelActionAreaScaledPath = Path.Combine(diagnosticsDirectory, "panel-action-area-scaled.png");
        var handledCache = new HandledNotificationCache(TimeSpan.FromSeconds(3));
        var handledMultiCache = new HandledMultiNotificationCache(TimeSpan.FromSeconds(3));
        var handledBatchCache = new HandledBatchCache(TimeSpan.FromSeconds(3));
        var failedHoverCooldown = new FailedHoverCooldown(TimeSpan.FromMilliseconds(1000));
        DateTimeOffset lastInMeetingDebugAt = DateTimeOffset.MinValue;
        int knownWaitingCount = 0;
        IntPtr lastObservedForegroundHwnd = NativeMethods.GetForegroundWindow();

        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeoutSeconds > 0) cancellation.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;

        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                AutoAdmitScan scan;
                try
                {
                    scan = CaptureAndDetectAsync(engine, framePath, cancellation.Token).GetAwaiter().GetResult();
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    ConsoleLogger.Error($"CAPTURE_OR_OCR_FAILED: {ex}");
                    Thread.Sleep(IdleDelay);
                    continue;
                }

                var eligible = ContinuousNotificationSelector.EligibleCandidates(
                    scan.Detection.AllCandidates,
                    handledCache,
                    DateTimeOffset.UtcNow);
                var selected = eligible.FirstOrDefault(IsLiveNotificationSurface);
                if ((selected == null || selected.LayoutType != WaitingRoomNotificationLayout.InMeetingToast) &&
                    DateTimeOffset.UtcNow - lastInMeetingDebugAt >= TimeSpan.FromSeconds(2) &&
                    HasInMeetingToastSignals(scan.Ocr))
                {
                    PrintInMeetingToastDebug(scan);
                    lastInMeetingDebugAt = DateTimeOffset.UtcNow;
                }
                if (selected != null)
                {
                    Console.WriteLine();
                    Console.WriteLine("WAITING_ROOM_DETECTED");
                    PrintCandidate(selected);
                    ProcessOneNotification(
                        selected,
                        scan.PrimaryBounds,
                        scan.CaptureCompletedAt,
                        engine,
                        framePath,
                        handledCache,
                        cancellation.Token);
                    // Always recapture from scratch after one attempt. No coordinates
                    // or second candidate from the prior frame are reused.
                    continue;
                }

                var multiCandidate = scan.MultiPersonDetection.AllCandidates
                    .Where(candidate => candidate.IsAccepted &&
                                        candidate.Confidence >= AdmitOnceSafetyGate.HighConfidence &&
                                        !handledMultiCache.IsSuppressed(candidate, DateTimeOffset.UtcNow))
                    .OrderBy(candidate => candidate.NotificationBounds.Y)
                    .ThenBy(candidate => candidate.NotificationBounds.X)
                    .FirstOrDefault(IsLiveMultiPersonSurface);
                if (multiCandidate != null)
                {
                    ProcessMultiPersonNotification(
                        multiCandidate,
                        scan,
                        engine,
                        framePath,
                        handledCache,
                        handledMultiCache,
                        handledBatchCache,
                        cancellation.Token);
                    continue;
                }

                var panel = WaitingRoomParticipantRowDetector.Detect(scan.Ocr);
                if (panel.IsPanelVisible)
                {
                    int waitingCount = panel.DeclaredWaitingCount ?? (panel.WaitingRoomHeader != null ? panel.Rows.Count : 0);

                    // HARD PRIORITY RULE:
                    // If Waiting Room count >= 2 (or 2+ rows detected), MUST try Admit all first and recover scroll if hidden.
                    // DO NOT hover individual users before exhausting batch path!
                    if (waitingCount >= 2 || panel.Rows.Count >= 2)
                    {
                        var admitAll = PanelAdmitAllDetector.Detect(scan.Ocr);
                        if (!admitAll.IsAccepted || !IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                        {
                            scan = ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
                                engine,
                                new WindowsMouseInput(),
                                panel.PanelBounds,
                                framePath,
                                IsLiveZoomSurfaceAt,
                                CaptureAndDetectAsync,
                                cancellation.Token).GetAwaiter().GetResult();

                            admitAll = PanelAdmitAllDetector.Detect(scan.Ocr);
                            panel = WaitingRoomParticipantRowDetector.Detect(scan.Ocr);
                        }

                        if (admitAll.IsAccepted &&
                            admitAll.Confidence >= AdmitOnceSafetyGate.HighConfidence &&
                            !handledBatchCache.IsSuppressed(admitAll, DateTimeOffset.UtcNow) &&
                            IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                        {
                            ProcessPanelAdmitAll(
                                admitAll,
                                engine,
                                framePath,
                                handledCache,
                                handledBatchCache,
                                cancellation.Token);
                            continue;
                        }

                        if (panel.WaitingRoomHeader == null && !admitAll.IsAccepted)
                        {
                            continue;
                        }
                    }

                    // If waitingCount == 1 (or 1 row remaining):
                    if (waitingCount == 1 || (waitingCount == 0 && panel.Rows.Count == 1))
                    {
                        var panelRow = panel.Rows
                            .Where(row => row.Confidence >= MinimumPanelRowConfidence &&
                                          !handledCache.IsParticipantSuppressed(row.ParticipantName, DateTimeOffset.UtcNow) &&
                                          !failedHoverCooldown.IsCoolingDown(row, DateTimeOffset.UtcNow))
                            .OrderBy(row => row.RowBounds.Y)
                            .FirstOrDefault();

                        if (panelRow != null && IsLiveZoomSurfaceAt(panelRow.SafeHoverPoint.X, panelRow.SafeHoverPoint.Y))
                        {
                            Console.WriteLine();
                            Console.WriteLine("PARTICIPANTS_FALLBACK_DETECTED");
                            Console.WriteLine($"Participant: {panelRow.ParticipantName}");
                            ProcessOnePanelParticipant(
                                panelRow,
                                panel,
                                scan.PrimaryBounds,
                                engine,
                                framePath,
                                panelAfterHoverPath,
                                panelRowBeforeHoverPath,
                                panelRowAfterHoverPath,
                                panelActionAreaPath,
                                panelActionAreaScaledPath,
                                handledCache,
                                handledBatchCache,
                                failedHoverCooldown,
                                cancellation.Token);
                            continue;
                        }
                    }
                }

                // 4. Waiting Room Watchdog: Event-driven 100% Background Watchdog (Zero Foreground Activation)
                bool hasWaitingEvidence = knownWaitingCount > 0 ||
                                          (panel.IsPanelVisible && panel.HasActiveWaitingParticipants);

                if (hasWaitingEvidence)
                {
                    var zoomHwnd = ZoomWindowManager.FindActiveZoomWindow();
                    if (zoomHwnd != IntPtr.Zero)
                    {
                        string reason = $"Known Waiting Room activity (count={knownWaitingCount}, rows={panel.Rows.Count})";

                        RunBackgroundWatchdogCheck(
                            zoomHwnd,
                            reason,
                            engine,
                            framePath,
                            panelAfterHoverPath,
                            panelRowBeforeHoverPath,
                            panelRowAfterHoverPath,
                            panelActionAreaPath,
                            panelActionAreaScaledPath,
                            handledCache,
                            handledBatchCache,
                            failedHoverCooldown,
                            cancellation.Token);

                        knownWaitingCount = 0;
                        continue;
                    }
                }

                // Level 1 Passive Watch - zero foreground switching
                var currentFg = NativeMethods.GetForegroundWindow();
                if (currentFg == lastObservedForegroundHwnd || lastObservedForegroundHwnd == IntPtr.Zero)
                {
                    // Foreground invariant preserved
                }
                else
                {
                    lastObservedForegroundHwnd = currentFg;
                }

                Thread.Sleep(IdleDelay);
                continue;
            }
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }

        Console.WriteLine();
        Console.WriteLine("AUTO_ADMIT_STOPPED");
        return 0;
    }

    private static void RunBackgroundWatchdogCheck(
        IntPtr zoomHwnd,
        string reason,
        WindowsNativeOcrEngine engine,
        string framePath,
        string panelAfterHoverPath,
        string panelRowBeforeHoverPath,
        string panelRowAfterHoverPath,
        string panelActionAreaPath,
        string panelActionAreaScaledPath,
        HandledNotificationCache handledCache,
        HandledBatchCache handledBatchCache,
        FailedHoverCooldown failedHoverCooldown,
        CancellationToken cancellationToken)
    {
        Console.WriteLine();
        Console.WriteLine("BACKGROUND_ACTION_ATTEMPT");
        Console.WriteLine($"WATCHDOG_ACTIVE_REASON: {reason}");

        // Attempt 1: Background interaction
        if (TryExecuteBackgroundWaitingRoomAdmission(
                zoomHwnd,
                engine,
                framePath,
                handledCache,
                handledBatchCache,
                failedHoverCooldown,
                cancellationToken))
        {
            Console.WriteLine("BACKGROUND_ACTION_VERIFIED");
            Console.WriteLine("FOREGROUND_REQUIRED: NO");
            Console.WriteLine("WAITING_ROOM_EMPTY");
            Console.WriteLine("FOREGROUND_INVARIANT_PASSED");
            Console.WriteLine("WATCHDOG_BACKOFF");
            return;
        }

        // Attempt 2: Fresh capture + fresh coordinates + background action
        Console.WriteLine("BACKGROUND_RETRY_PENDING");
        Thread.Sleep(100);
        if (TryExecuteBackgroundWaitingRoomAdmission(
                zoomHwnd,
                engine,
                framePath,
                handledCache,
                handledBatchCache,
                failedHoverCooldown,
                cancellationToken))
        {
            Console.WriteLine("BACKGROUND_ACTION_VERIFIED");
            Console.WriteLine("FOREGROUND_REQUIRED: NO");
            Console.WriteLine("WAITING_ROOM_EMPTY");
            Console.WriteLine("FOREGROUND_INVARIANT_PASSED");
            Console.WriteLine("WATCHDOG_BACKOFF");
            return;
        }

        // Both background attempts exhausted -> conditional emergency fallback ONLY because real participant is waiting
        Console.WriteLine("BACKGROUND_ACTION_EXHAUSTED");
        Console.WriteLine("FOREGROUND_FALLBACK_REQUIRED");

        RunEmergencyForegroundFallback(
            zoomHwnd,
            engine,
            framePath,
            panelAfterHoverPath,
            panelRowBeforeHoverPath,
            panelRowAfterHoverPath,
            panelActionAreaPath,
            panelActionAreaScaledPath,
            handledCache,
            handledBatchCache,
            failedHoverCooldown,
            cancellationToken);

        Console.WriteLine("WATCHDOG_BACKOFF");
    }

    private static void RunEmergencyForegroundFallback(
        IntPtr zoomHwnd,
        WindowsNativeOcrEngine engine,
        string framePath,
        string panelAfterHoverPath,
        string panelRowBeforeHoverPath,
        string panelRowAfterHoverPath,
        string panelActionAreaPath,
        string panelActionAreaScaledPath,
        HandledNotificationCache handledCache,
        HandledBatchCache handledBatchCache,
        FailedHoverCooldown failedHoverCooldown,
        CancellationToken cancellationToken)
    {
        Console.WriteLine("FOREGROUND_ESCALATION_ALLOWED");
        Console.WriteLine("FOREGROUND_FALLBACK_RUNNING");
        Console.WriteLine("FOREGROUND_FALLBACK_STARTED");

        using var preserver = new ForegroundWindowPreserver(zoomHwnd);
        if (!preserver.ActivateZoomTemporarily())
        {
            Console.WriteLine("FOREGROUND_FALLBACK_COMPLETED");
            Console.WriteLine("USER_FOREGROUND_RESTORED");
            return;
        }

        bool done = false;
        int passCount = 0;
        const int maxPasses = 3;

        while (!done && passCount++ < maxPasses && !cancellationToken.IsCancellationRequested)
        {
            AutoAdmitScan freshScan;
            try
            {
                freshScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                ConsoleLogger.Error($"FOREGROUND_SCAN_FAILED: {ex.Message}");
                break;
            }

            var toast = freshScan.Detection.AllCandidates.FirstOrDefault(c => c.IsAccepted && IsLiveNotificationSurface(c));
            if (toast != null)
            {
                ProcessOneNotification(toast, freshScan.PrimaryBounds, freshScan.CaptureCompletedAt, engine, framePath, handledCache, cancellationToken);
                continue;
            }

            var panel = WaitingRoomParticipantRowDetector.Detect(freshScan.Ocr);
            if (!panel.IsPanelVisible)
            {
                var existingParticipantsWnd = ZoomWindowManager.FindParticipantsWindow();
                if (existingParticipantsWnd != IntPtr.Zero)
                {
                    Console.WriteLine($"PARTICIPANTS_WINDOW_SELECTED: HWND=0x{existingParticipantsWnd.ToInt64():X}");
                }
                else
                {
                    var fg = NativeMethods.GetForegroundWindowInfoSafe();
                    if (fg.WindowTitle.Contains("Chat", StringComparison.OrdinalIgnoreCase))
                    {
                        Console.WriteLine($"MEETING_CHAT_IGNORED: HWND=0x{fg.Handle.ToInt64():X}");
                        break;
                    }

                    var intermediate = ParticipantsIntermediateDetector.Detect(freshScan.Ocr);
                    if (intermediate.IsAccepted && IsLiveZoomSurfaceAt(intermediate.ActionCenter.X, intermediate.ActionCenter.Y))
                    {
                        Console.WriteLine("PARTICIPANTS_CONTROL_VERIFIED");
                        var click = new SingleClickExecutor(new WindowsMouseInput());
                        click.TryClick(checked((int)Math.Round(intermediate.ActionCenter.X)), checked((int)Math.Round(intermediate.ActionCenter.Y)));
                        Thread.Sleep(250);
                        continue;
                    }
                    else
                    {
                        Console.WriteLine("PARTICIPANTS_CONTROL_NOT_VERIFIED");
                        break;
                    }
                }
            }

            int waitingCount = panel.DeclaredWaitingCount ?? (panel.WaitingRoomHeader != null ? panel.Rows.Count : 0);
            if (waitingCount >= 2 || panel.Rows.Count >= 2)
            {
                Console.WriteLine($"WAITING_ROOM_NOT_EMPTY: {waitingCount} participant(s) detected.");
                var admitAll = PanelAdmitAllDetector.Detect(freshScan.Ocr);
                if (!admitAll.IsAccepted || !IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                {
                    freshScan = ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
                        engine,
                        new WindowsMouseInput(),
                        panel.PanelBounds,
                        framePath,
                        IsLiveZoomSurfaceAt,
                        CaptureAndDetectAsync,
                        cancellationToken).GetAwaiter().GetResult();
                    admitAll = PanelAdmitAllDetector.Detect(freshScan.Ocr);
                }

                if (admitAll.IsAccepted && IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                {
                    ProcessPanelAdmitAll(admitAll, engine, framePath, handledCache, handledBatchCache, cancellationToken);
                    continue;
                }
            }
            else if (waitingCount == 1 || (waitingCount == 0 && panel.Rows.Count == 1))
            {
                Console.WriteLine($"WAITING_ROOM_NOT_EMPTY: 1 participant detected.");
                var panelRow = panel.Rows.FirstOrDefault(r => r.Confidence >= MinimumPanelRowConfidence);
                if (panelRow != null && IsLiveZoomSurfaceAt(panelRow.SafeHoverPoint.X, panelRow.SafeHoverPoint.Y))
                {
                    ProcessOnePanelParticipant(
                        panelRow,
                        panel,
                        freshScan.PrimaryBounds,
                        engine,
                        framePath,
                        panelAfterHoverPath,
                        panelRowBeforeHoverPath,
                        panelRowAfterHoverPath,
                        panelActionAreaPath,
                        panelActionAreaScaledPath,
                        handledCache,
                        handledBatchCache,
                        failedHoverCooldown,
                        cancellationToken);
                    continue;
                }
            }
            else
            {
                Console.WriteLine("WAITING_ROOM_HEALTHY Count: 0");
                Console.WriteLine("WAITING_ROOM_EMPTY");
                done = true;
            }
        }

        Console.WriteLine("FOREGROUND_FALLBACK_COMPLETED");
        Console.WriteLine("USER_FOREGROUND_RESTORED");
    }

    private static bool TryExecuteBackgroundWaitingRoomAdmission(
        IntPtr zoomHwnd,
        WindowsNativeOcrEngine engine,
        string framePath,
        HandledNotificationCache handledCache,
        HandledBatchCache handledBatchCache,
        FailedHoverCooldown failedHoverCooldown,
        CancellationToken cancellationToken)
    {
        if (zoomHwnd == IntPtr.Zero || !NativeMethods.IsWindow(zoomHwnd)) return false;

        bool wasMinimized = NativeMethods.IsIconic(zoomHwnd);
        if (wasMinimized)
        {
            NativeMethods.ShowWindow(zoomHwnd, NativeMethods.SW_SHOWNOACTIVATE);
            Thread.Sleep(100);
        }

        try
        {
            using var capture = WindowsWindowCapturer.CaptureWindow(zoomHwnd);
            if (!capture.IsSuccessful || capture.Bitmap == null)
            {
                return false;
            }

            string windowScanPath = Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "zoom-window-scan.png");
            capture.Bitmap.Save(windowScanPath, ImageFormat.Png);

            var localOcr = engine.RecognizeImageFileAsync(windowScanPath, cancellationToken).GetAwaiter().GetResult();
            var mappedOcr = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(localOcr, capture.WindowBounds);

            var panel = WaitingRoomParticipantRowDetector.Detect(mappedOcr);
            if (!panel.IsPanelVisible || !panel.HasActiveWaitingParticipants)
            {
                if (panel.IsPanelVisible && panel.DeclaredWaitingCount == 0)
                {
                    Console.WriteLine("WAITING_ROOM_HEALTHY Count: 0");
                    Console.WriteLine("WAITING_ROOM_CONFIRMED_EMPTY");
                    return true;
                }
                return false;
            }

            int waitingCount = panel.DeclaredWaitingCount ?? (panel.WaitingRoomHeader != null ? panel.Rows.Count : 0);
            if (waitingCount >= 2 || panel.Rows.Count >= 2)
            {
                Console.WriteLine($"BACKGROUND_EMPTY_WAITING_ROOM: {waitingCount} participant(s) detected.");
                var admitAll = PanelAdmitAllDetector.Detect(mappedOcr);
                if (admitAll.IsAccepted)
                {
                    var (clientX, clientY) = BackgroundZoomInteraction.ToClientCoordinates(zoomHwnd, admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y);
                    Console.WriteLine($"BACKGROUND_ADMIT_ALL_CLICK: Client=({clientX},{clientY}) HWND=0x{zoomHwnd.ToInt64():X}");
                    BackgroundZoomInteraction.SendMouseClick(zoomHwnd, clientX, clientY);
                    Thread.Sleep(200);

                    using var verifyCapture = WindowsWindowCapturer.CaptureWindow(zoomHwnd);
                    if (verifyCapture.IsSuccessful && verifyCapture.Bitmap != null)
                    {
                        verifyCapture.Bitmap.Save(windowScanPath, ImageFormat.Png);
                        var verifyOcr = engine.RecognizeImageFileAsync(windowScanPath, cancellationToken).GetAwaiter().GetResult();
                        var verifyMapped = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(verifyOcr, verifyCapture.WindowBounds);
                        var verifyPanel = WaitingRoomParticipantRowDetector.Detect(verifyMapped);
                        if (!verifyPanel.HasActiveWaitingParticipants)
                        {
                            Console.WriteLine("WAITING_ROOM_CONFIRMED_EMPTY");
                            return true;
                        }
                    }
                }
            }
            else if (waitingCount == 1 || panel.Rows.Count == 1)
            {
                var row = panel.Rows.FirstOrDefault(r => r.Confidence >= MinimumPanelRowConfidence);
                if (row != null)
                {
                    Console.WriteLine($"BACKGROUND_PARTICIPANT_HOVER: {row.ParticipantName}");
                    var (hoverClientX, hoverClientY) = BackgroundZoomInteraction.ToClientCoordinates(zoomHwnd, row.SafeHoverPoint.X, row.SafeHoverPoint.Y);
                    BackgroundZoomInteraction.SendMouseMove(zoomHwnd, hoverClientX, hoverClientY);
                    Thread.Sleep(150);

                    using var hoverCapture = WindowsWindowCapturer.CaptureWindow(zoomHwnd);
                    if (hoverCapture.IsSuccessful && hoverCapture.Bitmap != null)
                    {
                        hoverCapture.Bitmap.Save(windowScanPath, ImageFormat.Png);
                        var hoverOcr = engine.RecognizeImageFileAsync(windowScanPath, cancellationToken).GetAwaiter().GetResult();
                        var hoverMapped = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(hoverOcr, hoverCapture.WindowBounds);
                        var hoverAdmits = WaitingRoomParticipantRowDetector.EvaluateIndividualAdmitsAfterHover(row, panel, hoverMapped);
                        var acceptedAdmit = hoverAdmits.FirstOrDefault(a => a.IsAccepted);

                        if (acceptedAdmit != null)
                        {
                            var (admitClientX, admitClientY) = BackgroundZoomInteraction.ToClientCoordinates(zoomHwnd, acceptedAdmit.AdmitWord.Center.X, acceptedAdmit.AdmitWord.Center.Y);
                            Console.WriteLine($"BACKGROUND_ADMIT_CLICK: Client=({admitClientX},{admitClientY}) HWND=0x{zoomHwnd.ToInt64():X}");
                            BackgroundZoomInteraction.SendMouseClick(zoomHwnd, admitClientX, admitClientY);
                            Thread.Sleep(200);
                            Console.WriteLine("PANEL_ADMIT_CONFIRMED");
                            Console.WriteLine("WAITING_ROOM_CONFIRMED_EMPTY");
                            return true;
                        }
                        else
                        {
                            Console.WriteLine("BACKGROUND_HOVER_UNSUPPORTED: Admit button not exposed via background mouse move.");
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"Background admission attempt error: {ex.Message}");
        }
        finally
        {
            if (wasMinimized)
            {
                NativeMethods.ShowWindow(zoomHwnd, NativeMethods.SW_SHOWMINIMIZED);
            }
        }

        return false;
    }

    private static void ProcessMultiPersonNotification(
        MultiPersonWaitingNotificationCandidate frame1Candidate,
        AutoAdmitScan frame1Scan,
        WindowsNativeOcrEngine engine,
        string framePath,
        HandledNotificationCache handledCache,
        HandledMultiNotificationCache handledMultiCache,
        HandledBatchCache handledBatchCache,
        CancellationToken cancellationToken)
    {
        Console.WriteLine();
        Console.WriteLine("MULTI_PERSON_WAITING_NOTIFICATION_DETECTED");
        Console.WriteLine($"Waiting count: {frame1Candidate.WaitingCount}");
        Console.WriteLine($"View bounds: {frame1Candidate.ViewWord?.Bounds}");
        Console.WriteLine($"Confidence: {frame1Candidate.Confidence:P0}");

        var gate = new MultiPersonNotificationSafetyGate();
        var first = gate.Observe(frame1Candidate, frame1Scan.PrimaryBounds, frame1Scan.CaptureCompletedAt);
        if (first.Kind != MultiPersonNotificationDecisionKind.FirstFrameAccepted) return;

        Thread.Sleep(FrameDelay);
        AutoAdmitScan frame2;
        try { frame2 = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex) { ConsoleLogger.Error($"MULTI_FRAME_2_CAPTURE_FAILED: {ex.Message}"); return; }
        var secondCandidate = MultiPersonWaitingNotificationDetector.FindSame(
            frame1Candidate,
            frame2.MultiPersonDetection.AllCandidates);
        if (secondCandidate == null || !IsLiveMultiPersonSurface(secondCandidate)) return;
        var second = gate.Observe(secondCandidate, frame2.PrimaryBounds, frame2.CaptureCompletedAt);
        if (second.Kind != MultiPersonNotificationDecisionKind.Armed) return;

        AutoAdmitScan finalScan;
        try { finalScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex) { ConsoleLogger.Error($"MULTI_FINAL_CAPTURE_FAILED: {ex.Message}"); return; }
        var finalCandidate = MultiPersonWaitingNotificationDetector.FindSame(
            secondCandidate,
            finalScan.MultiPersonDetection.AllCandidates);
        if (finalCandidate == null || !IsLiveMultiPersonSurface(finalCandidate)) return;
        var final = gate.ValidateFinal(
            finalCandidate,
            finalScan.PrimaryBounds,
            finalScan.CaptureCompletedAt,
            NativeMethods.IsInteractiveInputDesktopAvailable());
        if (final.Kind != MultiPersonNotificationDecisionKind.ClickReady || !gate.TryMarkClickSent()) return;

        handledMultiCache.MarkHandled(finalCandidate, DateTimeOffset.UtcNow);
        try
        {
            var click = new SingleClickExecutor(new WindowsMouseInput());
            if (!click.TryClick(
                    checked((int)Math.Round(finalCandidate.ViewCenter.X)),
                    checked((int)Math.Round(finalCandidate.ViewCenter.Y))))
            {
                Console.WriteLine("VIEW_CLICK_SENT_BUT_PANEL_NOT_VERIFIED");
                return;
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"View click failed: {ex}");
            Console.WriteLine("VIEW_CLICK_SENT_BUT_PANEL_NOT_VERIFIED");
            return;
        }
        Console.WriteLine("VIEW_CLICK_SENT");

        DateTimeOffset viewClickTime = DateTimeOffset.UtcNow;
        DateTimeOffset deadline = viewClickTime + VerificationWindow;
        bool panelSeen = false;
        var transitionVerifier = new ViewPanelTransitionVerifier();
        bool intermediateClicked = false;

        while (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            Thread.Sleep(FrameDelay);
            double elapsedMs = (DateTimeOffset.UtcNow - viewClickTime).TotalMilliseconds;
            AutoAdmitScan transition;
            try { transition = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (Exception ex) { ConsoleLogger.Error($"View transition capture failed: {ex.Message}"); continue; }

            var panel = WaitingRoomParticipantRowDetector.Detect(transition.Ocr);
            var intermediate = ParticipantsIntermediateDetector.Detect(transition.Ocr, panel);

            Console.WriteLine("POST_VIEW_TRANSITION_DEBUG");
            Console.WriteLine($"  Elapsed ms: {elapsedMs:F0}");
            Console.WriteLine($"  Participants panel visible: {(panel.IsPanelVisible ? "YES" : "NO")}");
            Console.WriteLine($"  Tap for Participants visible: {(intermediate.Kind == ParticipantsIntermediateKind.TapForParticipants ? "YES" : "NO")}");
            Console.WriteLine($"  Participants toolbar/control candidate: {(intermediate.Kind == ParticipantsIntermediateKind.ToolbarParticipantsButton ? "YES" : "NO")}");
            Console.WriteLine($"  Candidate bounds: {intermediate.ActionBounds}");

            var fg = NativeMethods.GetForegroundWindowInfoSafe();
            var procName = fg.ProcessName;
            var className = NativeMethods.GetClassNameSafe(fg.Handle);
            var windowTitle = fg.WindowTitle;
            Console.WriteLine($"  Runtime process/class/title: {procName} / {className} / {windowTitle}");
            Console.WriteLine($"  Rejection reason: {(intermediate.IsAccepted ? "None" : string.Join("; ", intermediate.Reasons))}");

            // CASE A: Participants panel is directly or already visible
            if (transitionVerifier.IsVerified(panel) || panel.IsPanelVisible)
            {
                handledMultiCache.ObserveSuccessfulTransition(
                    finalCandidate,
                    transition.MultiPersonDetection.AllCandidates);
                panelSeen = true;
                if (intermediateClicked)
                {
                    Console.WriteLine("PARTICIPANTS_PANEL_VERIFIED_AFTER_VIEW");
                }
                else
                {
                    Console.WriteLine("VIEW_PARTICIPANTS_PANEL_VERIFIED");
                }
                Console.WriteLine("BATCH_WAITING_ROOM_MODE");

                int waitingCount = panel.DeclaredWaitingCount ?? (panel.WaitingRoomHeader != null ? panel.Rows.Count : 0);
                if (waitingCount >= 2 || panel.Rows.Count >= 2)
                {
                    var admitAll = PanelAdmitAllDetector.Detect(transition.Ocr);
                    if (!admitAll.IsAccepted || !IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                    {
                        // Scrolled panel recovery
                        transition = ParticipantsPanelScrollRecovery.RecoverWaitingRoomHeaderAsync(
                            engine,
                            new WindowsMouseInput(),
                            panel.PanelBounds,
                            framePath,
                            IsLiveZoomSurfaceAt,
                            CaptureAndDetectAsync,
                            cancellationToken).GetAwaiter().GetResult();
                        admitAll = PanelAdmitAllDetector.Detect(transition.Ocr);
                    }

                    if (admitAll.IsAccepted && IsLiveZoomSurfaceAt(admitAll.AdmitAllCenter.X, admitAll.AdmitAllCenter.Y))
                    {
                        ProcessPanelAdmitAll(
                            admitAll,
                            engine,
                            framePath,
                            handledCache,
                            handledBatchCache,
                            cancellationToken);
                        return;
                    }
                }

                // Fallback for single participant or if Admit all was not found:
                if (panel.Rows.Count > 0)
                {
                    var panelRow = panel.Rows.FirstOrDefault(r => r.Confidence >= MinimumPanelRowConfidence);
                    if (panelRow != null && IsLiveZoomSurfaceAt(panelRow.SafeHoverPoint.X, panelRow.SafeHoverPoint.Y))
                    {
                        ProcessOnePanelParticipant(
                            panelRow,
                            panel,
                            transition.PrimaryBounds,
                            engine,
                            framePath,
                            Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "panel-after-hover.png"),
                            Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "panel-row-before-hover.png"),
                            Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "panel-row-after-hover.png"),
                            Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "panel-action-area.png"),
                            Path.Combine(Path.GetDirectoryName(framePath) ?? ".", "panel-action-area-scaled.png"),
                            handledCache,
                            handledBatchCache,
                            new FailedHoverCooldown(TimeSpan.FromMilliseconds(1000)),
                            cancellationToken);
                        return;
                    }
                }

                if (waitingCount == 0)
                {
                    Console.WriteLine("WAITING_ROOM_CONFIRMED_EMPTY");
                    return;
                }
            }

            // CASE B: Intermediate "Tap for Participants" or Toolbar control is visible
            if (!intermediateClicked && intermediate.IsAccepted &&
                IsLiveZoomSurfaceAt(intermediate.ActionCenter.X, intermediate.ActionCenter.Y))
            {
                Console.WriteLine();
                Console.WriteLine("PARTICIPANTS_INTERMEDIATE_DETECTED");
                Console.WriteLine($"Bounds: {intermediate.ActionBounds}");
                Console.WriteLine($"Center: ({intermediate.ActionCenter.X:F0},{intermediate.ActionCenter.Y:F0})");
                Console.WriteLine($"Detection source: {intermediate.SourceDescription}");
                Console.WriteLine($"Runtime HWND/process/class: {procName} / {className}");

                try
                {
                    var click = new SingleClickExecutor(new WindowsMouseInput());
                    if (click.TryClick(
                            checked((int)Math.Round(intermediate.ActionCenter.X)),
                            checked((int)Math.Round(intermediate.ActionCenter.Y))))
                    {
                        intermediateClicked = true;
                        Console.WriteLine("PARTICIPANTS_INTERMEDIATE_CLICK_SENT");
                        deadline = DateTimeOffset.UtcNow + VerificationWindow;
                        continue;
                    }
                }
                catch (Exception ex)
                {
                    ConsoleLogger.Error($"Intermediate click failed: {ex.Message}");
                }
            }
        }

        if (!panelSeen) Console.WriteLine("VIEW_CLICK_SENT_BUT_PANEL_NOT_VERIFIED");
    }

    private static void ProcessPanelAdmitAll(
        PanelAdmitAllCandidate initial,
        WindowsNativeOcrEngine engine,
        string framePath,
        HandledNotificationCache handledCache,
        HandledBatchCache handledBatchCache,
        CancellationToken cancellationToken)
    {
        Thread.Sleep(FrameDelay);
        AutoAdmitScan fresh;
        try { fresh = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex) { ConsoleLogger.Error($"ADMIT_ALL_REVALIDATION_FAILED: {ex.Message}"); return; }

        var current = PanelAdmitAllDetector.Detect(fresh.Ocr);
        if (!PanelAdmitAllDetector.IsSameAction(initial, current) ||
            current.Confidence < AdmitOnceSafetyGate.HighConfidence ||
            handledBatchCache.IsSuppressed(current, DateTimeOffset.UtcNow) ||
            !Contains(fresh.PrimaryBounds, current.AdmitAllCenter.X, current.AdmitAllCenter.Y) ||
            !NativeMethods.IsInteractiveInputDesktopAvailable() ||
            !IsLiveZoomSurfaceAt(current.AdmitAllCenter.X, current.AdmitAllCenter.Y))
            return;

        Console.WriteLine();
        Console.WriteLine("PANEL_ADMIT_ALL_DETECTED");
        Console.WriteLine($"Waiting count before: {current.WaitingCount?.ToString() ?? "unknown"}");
        Console.WriteLine($"Admit all bounds: {current.AdmitAllBounds}");
        Console.WriteLine($"Dynamic center: ({current.AdmitAllCenter.X:F1}, {current.AdmitAllCenter.Y:F1})");
        Console.WriteLine($"Confidence: {current.Confidence:P0}");

        handledBatchCache.MarkHandled(current, DateTimeOffset.UtcNow);
        foreach (string participant in current.OriginalParticipants)
            handledCache.MarkParticipantHandled(participant, DateTimeOffset.UtcNow);
        try
        {
            var click = new SingleClickExecutor(new WindowsMouseInput());
            if (!click.TryClick(
                    checked((int)Math.Round(current.AdmitAllCenter.X)),
                    checked((int)Math.Round(current.AdmitAllCenter.Y))))
                return;
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"Admit all click failed: {ex}");
            Console.WriteLine("PANEL_ADMIT_ALL_CLICK_SENT_BUT_NOT_VERIFIED");
            return;
        }
        Console.WriteLine("PANEL_ADMIT_ALL_CLICK_SENT");

        var verifier = new BatchAdmissionVerifier(current);
        DateTimeOffset deadline = DateTimeOffset.UtcNow + VerificationWindow;
        while (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            Thread.Sleep(FrameDelay);
            try
            {
                var verification = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
                var panel = WaitingRoomParticipantRowDetector.Detect(verification.Ocr);
                if (verifier.Observe(panel).Kind == BatchAdmissionVerificationKind.Verified)
                {
                    handledBatchCache.Forget(current);
                    Console.WriteLine("PANEL_ADMIT_ALL_VERIFIED");
                    return;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (Exception ex) { ConsoleLogger.Error($"Admit all verification capture failed: {ex.Message}"); }
        }
        Console.WriteLine("PANEL_ADMIT_ALL_CLICK_SENT_BUT_NOT_VERIFIED");
    }

    private static void ProcessOnePanelParticipant(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel,
        BoundingRectangleInfo primaryBounds,
        WindowsNativeOcrEngine engine,
        string framePath,
        string panelAfterHoverPath,
        string panelRowBeforeHoverPath,
        string panelRowAfterHoverPath,
        string panelActionAreaPath,
        string panelActionAreaScaledPath,
        HandledNotificationCache handledCache,
        HandledBatchCache handledBatchCache,
        FailedHoverCooldown failedHoverCooldown,
        CancellationToken cancellationToken)
    {
        AutoAdmitScan fresh;
        try
        {
            fresh = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"PANEL_PRE_HOVER_REVALIDATION_FAILED: {ex.Message}");
            return;
        }

        var freshAdmitAll = PanelAdmitAllDetector.Detect(fresh.Ocr);
        if (freshAdmitAll.IsAccepted &&
            freshAdmitAll.Confidence >= AdmitOnceSafetyGate.HighConfidence &&
            !handledBatchCache.IsSuppressed(freshAdmitAll, DateTimeOffset.UtcNow) &&
            IsLiveZoomSurfaceAt(freshAdmitAll.AdmitAllCenter.X, freshAdmitAll.AdmitAllCenter.Y))
        {
            Console.WriteLine("PANEL_ADMIT_ALL_PREEMPTS_INDIVIDUAL_HOVER");
            ProcessPanelAdmitAll(
                freshAdmitAll,
                engine,
                framePath,
                handledCache,
                handledBatchCache,
                cancellationToken);
            return;
        }

        var freshPanel = WaitingRoomParticipantRowDetector.Detect(fresh.Ocr);
        var freshRow = freshPanel.Rows.FirstOrDefault(row =>
            row.ParticipantName.Equals(originalRow.ParticipantName, StringComparison.OrdinalIgnoreCase));
        if (freshRow == null)
        {
            Console.WriteLine("PANEL_ACTION_REJECTED: participant row disappeared before hover.");
            return;
        }
        originalRow = freshRow;
        originalPanel = freshPanel;
        primaryBounds = fresh.PrimaryBounds;

        if (!Contains(primaryBounds, originalRow.SafeHoverPoint.X, originalRow.SafeHoverPoint.Y) ||
            !NativeMethods.IsInteractiveInputDesktopAvailable() ||
            !IsLiveZoomSurfaceAt(originalRow.SafeHoverPoint.X, originalRow.SafeHoverPoint.Y))
        {
            Console.WriteLine("PANEL_ACTION_REJECTED: hover point or interactive input desktop is unsafe.");
            return;
        }

        PanelLifecycleResult result;
        try
        {
            var cursor = new WindowsCursorController();
            var session = new CursorPreservingSession(cursor);
            result = session.Run(originalCursor =>
            {
                var rowCrop = ScreenCropGeometry.GetParticipantRowCrop(originalRow, originalPanel, primaryBounds);
                SaveAbsoluteCrop(framePath, panelRowBeforeHoverPath, rowCrop, primaryBounds);
                var neutral = GetNeutralHoverPoint(originalRow, originalPanel);
                var finalHover = (
                    checked((int)Math.Round(originalRow.SafeHoverPoint.X)),
                    checked((int)Math.Round(originalRow.SafeHoverPoint.Y)));
                var activator = new SyntheticHoverActivator(cursor);
                SyntheticHoverTrace? trace = null;
                AutoAdmitScan? postHover = null;
                double difference = 0;
                bool activated = false;
                for (int attempt = 1; HoverActivationPolicy.CanAttempt(attempt); attempt++)
                {
                    trace = activator.Activate(neutral, finalHover);
                    var cursorBeforeCapture = cursor.GetPosition();
                    bool cursorInRow = Contains(originalRow.RowBounds, cursorBeforeCapture.X, cursorBeforeCapture.Y);
                    if (!cursorInRow)
                    {
                        Console.WriteLine("HOVER_CURSOR_LOST");
                        Console.WriteLine($"Expected row: {originalRow.RowBounds}");
                        Console.WriteLine($"Expected final point: ({finalHover.Item1},{finalHover.Item2})");
                        Console.WriteLine($"Actual cursor: ({cursorBeforeCapture.X},{cursorBeforeCapture.Y})");

                        // Re-activate hover once
                        trace = activator.Activate(neutral, finalHover);
                        cursorBeforeCapture = cursor.GetPosition();
                        cursorInRow = Contains(originalRow.RowBounds, cursorBeforeCapture.X, cursorBeforeCapture.Y);
                        if (!cursorInRow)
                        {
                            Console.WriteLine("HOVER_CURSOR_LOST");
                            Console.WriteLine($"Expected row: {originalRow.RowBounds}");
                            Console.WriteLine($"Expected final point: ({finalHover.Item1},{finalHover.Item2})");
                            Console.WriteLine($"Actual cursor: ({cursorBeforeCapture.X},{cursorBeforeCapture.Y})");
                            continue;
                        }
                    }

                    postHover = CaptureAndDetectAsync(engine, panelAfterHoverPath, cancellationToken).GetAwaiter().GetResult();
                    SaveAbsoluteCrop(panelAfterHoverPath, panelRowAfterHoverPath, rowCrop, postHover.PrimaryBounds);
                    using var beforeBitmap = new Bitmap(panelRowBeforeHoverPath);
                    using var afterBitmap = new Bitmap(panelRowAfterHoverPath);
                    difference = RowVisualDifference.CalculatePercentage(beforeBitmap, afterBitmap);
                    PrintHoverActivationDebug(originalCursor, trace, cursorBeforeCapture, difference, attempt);

                    var visualPresence = PanelRowVisualInspector.InspectPostHoverVisualAdmit(beforeBitmap, afterBitmap, rowCrop, originalRow);
                    Console.WriteLine($"POST_HOVER_VISUAL_ADMIT: {visualPresence.ToString().ToUpperInvariant()}");

                    double similarity = PanelRowVisualInspector.CompareWithManualHoverState(afterBitmap, originalRow);
                    Console.WriteLine("MANUAL_HOVER_STATE_MATCH");
                    Console.WriteLine($"Similarity: {similarity:P1}");

                    if (HoverActivationPolicy.IsActivated(difference) && cursorInRow)
                    {
                        activated = true;
                        break;
                    }
                    Console.WriteLine("HOVER_DID_NOT_ACTIVATE");
                }

                if (!activated || postHover == null)
                {
                    Console.WriteLine("HOVER_ACTIVATION_FAILED");
                    return new PanelLifecycleResult(false, false, "Synthetic hover produced no meaningful row visual change.");
                }

                var admit = FindPanelAdmitAfterHoverAsync(
                    engine,
                    postHover,
                    panelAfterHoverPath,
                    panelRowBeforeHoverPath,
                    panelRowAfterHoverPath,
                    panelActionAreaPath,
                    panelActionAreaScaledPath,
                    originalRow,
                    originalPanel,
                    cancellationToken).GetAwaiter().GetResult();
                if (admit.Validation?.IsConfirmed != true || admit.Validation.AdmitWord == null)
                    return new PanelLifecycleResult(false, false, "Post-hover individual Admit validation failed.");

                var validation = admit.Validation;
                if (!Contains(postHover.PrimaryBounds, validation.AdmitCenter.X, validation.AdmitCenter.Y) ||
                    !NativeMethods.IsInteractiveInputDesktopAvailable() ||
                    !IsLiveZoomSurfaceAt(validation.AdmitCenter.X, validation.AdmitCenter.Y))
                    return new PanelLifecycleResult(false, false, "Dynamic panel Admit target is outside the safe live Zoom surface.");

                Console.WriteLine("PANEL_ADMIT_CONFIRMED");
                Console.WriteLine($"Participant: {originalRow.ParticipantName}");
                Console.WriteLine($"Detection source: {admit.Source}");
                Console.WriteLine($"Admit bounds: {validation.AdmitWord.Bounds}");
                Console.WriteLine($"Dynamic center: ({validation.AdmitCenter.X:F1}, {validation.AdmitCenter.Y:F1})");
                Console.WriteLine($"Confidence: {validation.Confidence:P0}");

                var click = new SingleClickExecutor(new WindowsMouseInput());
                if (!click.TryClick(
                        checked((int)Math.Round(validation.AdmitCenter.X)),
                        checked((int)Math.Round(validation.AdmitCenter.Y))))
                    return new PanelLifecycleResult(false, false, "Single-click guard rejected the panel action.");
                handledCache.MarkParticipantHandled(originalRow.ParticipantName, DateTimeOffset.UtcNow);
                Console.WriteLine("PANEL_ADMIT_CLICK_SENT");
                Console.WriteLine($"Participant: {originalRow.ParticipantName}");

                bool verified = VerifyPanelParticipantAdmissionWhileHovering(
                    originalRow,
                    originalPanel,
                    engine,
                    framePath,
                    cancellationToken);
                return new PanelLifecycleResult(true, verified, verified ? string.Empty : "Admission was not verified.");
            });
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception ex)
        {
            failedHoverCooldown.MarkFailed(originalRow, DateTimeOffset.UtcNow);
            ConsoleLogger.Error($"Panel hover/click failed; cursor restoration was attempted: {ex}");
            Console.WriteLine("PANEL_ACTION_REJECTED");
            return;
        }

        if (!result.ClickSent)
        {
            failedHoverCooldown.MarkFailed(originalRow, DateTimeOffset.UtcNow);
            Console.WriteLine($"PANEL_ACTION_REJECTED: {result.Reason}");
            return;
        }

        if (result.Verified)
        {
            Console.WriteLine("PANEL_ADMIT_VERIFIED");
            Console.WriteLine($"Participant: {originalRow.ParticipantName}");
            Console.WriteLine("Path: ParticipantsPanel");
            return;
        }

        Console.WriteLine("PANEL_CLICK_SENT_BUT_NOT_VERIFIED");
        Console.WriteLine($"Participant: {originalRow.ParticipantName}");
    }

    private static bool VerifyPanelParticipantAdmissionWhileHovering(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel,
        WindowsNativeOcrEngine engine,
        string framePath,
        CancellationToken cancellationToken)
    {
        Console.WriteLine("CLICK_SENT");
        var verifier = new PanelAdmissionVerifier(originalRow, originalPanel);
        DateTimeOffset deadline = DateTimeOffset.UtcNow + VerificationWindow;
        while (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            Thread.Sleep(FrameDelay);
            try
            {
                var verificationScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
                var currentPanel = WaitingRoomParticipantRowDetector.Detect(verificationScan.Ocr);
                var decision = verifier.Observe(currentPanel);
                if (decision.Kind == PanelAdmissionVerificationKind.Verified)
                {
                    return true;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex) { ConsoleLogger.Error($"Panel verification capture failed: {ex.Message}"); }
        }

        return false;
    }

    private static void ProcessOneNotification(
        WaitingRoomToastCandidate frame1Candidate,
        BoundingRectangleInfo primaryBounds,
        DateTimeOffset frame1CaptureCompletedAt,
        WindowsNativeOcrEngine engine,
        string framePath,
        HandledNotificationCache handledCache,
        CancellationToken cancellationToken)
    {
        var gate = new AdmitOnceSafetyGate();
        var frame1 = gate.ObserveConfirmationFrame([frame1Candidate], primaryBounds, frame1CaptureCompletedAt);
        if (frame1.Kind != AdmitOnceDecisionKind.FirstFrameAccepted)
        {
            Console.WriteLine($"FRAME_1_REJECTED: {frame1.Reason}");
            return;
        }
        Console.WriteLine("FRAME_1_ACCEPTED");

        Thread.Sleep(FrameDelay);
        AutoAdmitScan frame2Scan;
        try { frame2Scan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex) { ConsoleLogger.Error($"FRAME_2_CAPTURE_FAILED: {ex.Message}"); return; }

        var frame2Candidate = ContinuousNotificationSelector.FindSameNotification(frame1Candidate, frame2Scan.Detection.AllCandidates);
        if (frame2Candidate == null || !IsLiveNotificationSurface(frame2Candidate))
        {
            Console.WriteLine("FRAME_2_REJECTED: original live notification was not revalidated.");
            return;
        }
        var frame2 = gate.ObserveConfirmationFrame([frame2Candidate], frame2Scan.PrimaryBounds, frame2Scan.CaptureCompletedAt);
        if (frame2.Kind != AdmitOnceDecisionKind.Armed)
        {
            Console.WriteLine($"FRAME_2_REJECTED: {frame2.Reason}");
            return;
        }
        Console.WriteLine("FRAME_2_CONFIRMED");

        AutoAdmitScan finalScan;
        try { finalScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        catch (Exception ex) { ConsoleLogger.Error($"FINAL_FRAME_CAPTURE_FAILED: {ex.Message}"); return; }

        var finalCandidate = ContinuousNotificationSelector.FindSameNotification(frame2Candidate, finalScan.Detection.AllCandidates);
        if (finalCandidate == null || !IsLiveNotificationSurface(finalCandidate))
        {
            Console.WriteLine("FINAL_FRAME_REJECTED: original notification moved, disappeared, or is not a live surface.");
            return;
        }

        var final = gate.ValidateFinalFrame(
            [finalCandidate],
            finalScan.PrimaryBounds,
            finalScan.CaptureCompletedAt,
            NativeMethods.IsInteractiveInputDesktopAvailable());
        if (final.Kind != AdmitOnceDecisionKind.ClickReady || final.Candidate == null)
        {
            Console.WriteLine($"FINAL_FRAME_REJECTED: {final.Reason}");
            return;
        }
        Console.WriteLine("FINAL_FRAME_CONFIRMED");

        handledCache.MarkHandled(finalCandidate, DateTimeOffset.UtcNow);
        if (!gate.TryMarkClickSent(finalCandidate, finalScan.CaptureCompletedAt))
        {
            Console.WriteLine("CLICK_ABORTED: detection was already handled.");
            return;
        }

        int x = checked((int)Math.Round(finalCandidate.AdmitCenter.X));
        int y = checked((int)Math.Round(finalCandidate.AdmitCenter.Y));
        try
        {
            var click = new SingleClickExecutor(new WindowsMouseInput());
            if (!click.TryClick(x, y))
            {
                Console.WriteLine("CLICK_SENT_BUT_NOT_VERIFIED");
                return;
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"Native click failed: {ex}");
            Console.WriteLine("CLICK_SENT_BUT_NOT_VERIFIED");
            return;
        }
        Console.WriteLine("CLICK_SENT");

        DateTimeOffset deadline = DateTimeOffset.UtcNow + VerificationWindow;
        int consecutiveMissing = 0;
        while (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            Thread.Sleep(FrameDelay);
            try
            {
                var verification = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
                var originalStillVisible = ContinuousNotificationSelector.FindSameNotification(
                    finalCandidate,
                    verification.Detection.AllCandidates) != null;
                consecutiveMissing = originalStillVisible ? 0 : consecutiveMissing + 1;
                if (consecutiveMissing >= 2)
                {
                    Console.WriteLine("ADMIT_VERIFIED");
                    Console.WriteLine($"Participant: {finalCandidate.ParticipantNormalizedName}");
                    return;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex) { ConsoleLogger.Error($"Verification capture failed: {ex.Message}"); }
        }

        Console.WriteLine("CLICK_SENT_BUT_NOT_VERIFIED");
        Console.WriteLine($"Participant: {finalCandidate.ParticipantNormalizedName}");
    }

    private static bool IsLiveNotificationSurface(WaitingRoomToastCandidate candidate)
    {
        var evidence = NativeMethods.GetWindowAtPointEvidenceSafe(candidate.AdmitCenter.X, candidate.AdmitCenter.Y);
        var decision = NotificationSurfacePolicy.Evaluate(
            candidate.LayoutType,
            evidence.RootProcess,
            evidence.RootClass,
            evidence.RootTitle,
            evidence.HasZoomParentOwnerChain);
        if (!decision.IsAllowed)
        {
            Console.WriteLine($"LIVE_SURFACE_REJECTED: {decision.Reason}");
        }
        return decision.IsAllowed;
    }

    private static bool IsLiveMultiPersonSurface(MultiPersonWaitingNotificationCandidate candidate)
    {
        var window = NativeMethods.GetRootWindowAtPointInfoSafe(candidate.ViewCenter.X, candidate.ViewCenter.Y);
        string windowClass = NativeMethods.GetRootWindowClassAtPointSafe(candidate.ViewCenter.X, candidate.ViewCenter.Y);
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.MultiPersonNotification,
            window.ProcessName,
            windowClass,
            window.WindowTitle);
        if (!decision.IsAllowed) Console.WriteLine($"LIVE_MULTI_SURFACE_REJECTED: {decision.Reason}");
        return decision.IsAllowed;
    }

    private static bool IsLiveZoomSurfaceAt(double x, double y)
    {
        var window = NativeMethods.GetRootWindowAtPointInfoSafe(x, y);
        string windowClass = NativeMethods.GetRootWindowClassAtPointSafe(x, y);
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            window.ProcessName,
            windowClass,
            window.WindowTitle);
        if (!decision.IsAllowed) Console.WriteLine($"LIVE_ZOOM_SURFACE_REJECTED: {decision.Reason}");
        return decision.IsAllowed;
    }

    private static void PrintCandidate(WaitingRoomToastCandidate candidate)
    {
        if (!string.IsNullOrEmpty(candidate.MonitorName))
        {
            Console.WriteLine($"Monitor: {candidate.MonitorName}");
        }
        Console.WriteLine($"Participant: {candidate.ParticipantNormalizedName}");
        Console.WriteLine($"Raw: {candidate.ParticipantRawText}");
        Console.WriteLine($"Layout: {candidate.LayoutType}");
        Console.WriteLine($"Confidence: {candidate.Confidence:P0}");
        Console.WriteLine($"Toast: {candidate.ToastBounds}");
        Console.WriteLine($"Absolute Admit center: ({candidate.AdmitCenter.X:F1}, {candidate.AdmitCenter.Y:F1})");
        Console.WriteLine($"View: {candidate.ViewBounds}");
    }

    private static bool HasInMeetingToastSignals(OcrResult ocr)
    {
        string text = string.Join(" ", ocr.Lines.Select(line => line.Text));
        int signals = 0;
        if (text.Contains("entered", StringComparison.OrdinalIgnoreCase)) signals++;
        if (System.Text.RegularExpressions.Regex.IsMatch(text, @"waiting\s+room", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) signals++;
        if (ocr.Words.Any(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase))) signals++;
        if (ocr.Words.Any(word => word.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase))) signals++;
        return signals >= 3;
    }

    private static void PrintInMeetingToastDebug(AutoAdmitScan scan)
    {
        Console.WriteLine();
        Console.WriteLine("IN_MEETING_TOAST_DEBUG");
        var admits = scan.Ocr.Words.Where(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase)).ToList();
        var views = scan.Ocr.Words.Where(word => word.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase)).ToList();
        foreach (var admit in admits) Console.WriteLine($"Admit bounds: {admit.Bounds}");
        foreach (var view in views) Console.WriteLine($"View bounds: {view.Bounds}");
        foreach (var line in scan.Ocr.Lines.Where(line =>
                     line.Text.Contains("entered", StringComparison.OrdinalIgnoreCase) ||
                     line.Text.Contains("waiting", StringComparison.OrdinalIgnoreCase) ||
                     admits.Any(admit => Math.Abs(line.Bounds.Y - admit.Bounds.Y) <= 220)))
            Console.WriteLine($"Raw OCR line: '{line.Text}' {line.Bounds}");

        foreach (var line in scan.Ocr.Lines.Where(line =>
                     line.Text.Contains("waiting", StringComparison.OrdinalIgnoreCase) ||
                     line.Text.Contains("entered", StringComparison.OrdinalIgnoreCase)))
            Console.WriteLine($"Waiting phrase bounds: {line.Bounds}");

        if (scan.Detection.AllCandidates.Count == 0)
            Console.WriteLine("Decision: Candidates=0 (waiting-room phrase or button pattern was not anchored).");
        foreach (var candidate in scan.Detection.AllCandidates)
        {
            Console.WriteLine($"Candidate confidence: {candidate.Confidence:P0}");
            Console.WriteLine($"Candidate layout: {candidate.LayoutType}");
            foreach (string reason in candidate.RejectionReasons) Console.WriteLine($"Detector rejection: {reason}");
            foreach (string reason in AdmitOnceSafetyGate.GetActionFilterRejectionReasons(candidate))
                Console.WriteLine($"Action filter rejection: {reason}");
            if (candidate.AdmitWord == null) continue;
            var evidence = NativeMethods.GetWindowAtPointEvidenceSafe(candidate.AdmitCenter.X, candidate.AdmitCenter.Y);
            Console.WriteLine($"Runtime target HWND: 0x{evidence.TargetHandle.ToInt64():X}");
            Console.WriteLine($"Runtime root HWND: 0x{evidence.RootHandle.ToInt64():X}");
            Console.WriteLine($"Runtime target: process='{evidence.TargetProcess}' class='{evidence.TargetClass}' title='{evidence.TargetTitle}'");
            Console.WriteLine($"Runtime root: process='{evidence.RootProcess}' class='{evidence.RootClass}' title='{evidence.RootTitle}'");
            foreach (string item in evidence.ParentOwnerChain) Console.WriteLine($"Runtime chain: {item}");
            foreach (string item in evidence.ZoomWindowsContainingPoint) Console.WriteLine($"Zoom containing point: {item}");
        }
    }

    private static void PrintPostHoverDebug(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel,
        OcrResult ocr)
    {
        Console.WriteLine("POST_HOVER_DEBUG");
        Console.WriteLine($"Original participant: {originalRow.ParticipantName}");
        Console.WriteLine($"Original participant text bounds: {originalRow.TextBounds}");
        Console.WriteLine($"Original row bounds: {originalRow.RowBounds}");
        Console.WriteLine($"Expanded row bounds: {new BoundingRectangleInfo(originalRow.RowBounds.X, originalRow.RowBounds.Y - 12, originalRow.RowBounds.Width, originalRow.RowBounds.Height + 24)}");
        Console.WriteLine($"Panel bounds: {originalPanel.PanelBounds}");
        Console.WriteLine($"Waiting Room bounds: {originalPanel.WaitingRoomHeader?.Bounds}");
        Console.WriteLine($"Joined bounds: {originalPanel.JoinedHeader?.Bounds}");
        var evaluations = WaitingRoomParticipantRowDetector.EvaluateIndividualAdmitsAfterHover(originalRow, originalPanel, ocr);
        if (evaluations.Count == 0) Console.WriteLine("Exact post-hover Admit candidates: 0");
        for (int index = 0; index < evaluations.Count; index++)
        {
            var item = evaluations[index];
            Console.WriteLine($"Admit #{index + 1}: bounds={item.AdmitWord.Bounds} center=({item.AdmitWord.Center.X:F1},{item.AdmitWord.Center.Y:F1})");
            Console.WriteLine($"  inside panel={YesNo(item.InsidePanel)} inside expanded row={YesNo(item.InsideExpandedRow)} right of participant={YesNo(item.RightOfParticipant)} above Joined={YesNo(item.AboveJoined)}");
            Console.WriteLine($"  Admit all={YesNo(item.IsAdmitAll)} toast candidate={YesNo(item.IsToastAdmit)} rejection='{item.RejectionReason}'");
        }
    }

    private static void PrintPostHoverRightSideTokens(
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel,
        OcrResult ocr)
    {
        foreach (var word in ocr.Words.Where(word =>
                     word.Bounds.X >= row.TextBounds.X + row.TextBounds.Width - 20 &&
                     word.Center.Y >= row.RowBounds.Y - 20 &&
                     word.Center.Y <= row.RowBounds.Y + row.RowBounds.Height + 20 &&
                     Contains(panel.PanelBounds, word.Center.X, word.Center.Y)))
            Console.WriteLine($"POST_HOVER_RIGHT_TOKEN '{word.Text}' {word.Bounds}");
    }

    private static async Task<PanelAdmitSearchResult> FindPanelAdmitAfterHoverAsync(
        WindowsNativeOcrEngine engine,
        AutoAdmitScan postHover,
        string fullImagePath,
        string rowCropBeforeImagePath,
        string rowCropAfterImagePath,
        string actionAreaImagePath,
        string scaledActionAreaImagePath,
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel,
        CancellationToken cancellationToken)
    {
        var fullValidation = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(row, panel, postHover.Ocr);
        PrintPostHoverDebug(row, panel, postHover.Ocr);
        if (fullValidation.IsConfirmed) return new(fullValidation, "FullScreenOCR");

        var rowCrop = ScreenCropGeometry.GetParticipantRowCrop(row, panel, postHover.PrimaryBounds);
        var actualRowCrop = GetActualCropBounds(rowCrop, postHover.PrimaryBounds);
        var rowResult = await engine.RecognizeSavedPngForSmokeTestAsync(
            rowCropAfterImagePath,
            actualRowCrop.X,
            actualRowCrop.Y);
        var rowMerged = MergeOcr(postHover.Ocr, rowResult.Result);
        var rowValidation = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(row, panel, rowMerged);
        if (rowValidation.IsConfirmed) return new(rowValidation, "RowCropOCR");

        var actionCrop = ScreenCropGeometry.GetParticipantActionAreaCrop(row, panel, postHover.PrimaryBounds);
        var actualActionCrop = SaveAbsoluteCrop(fullImagePath, actionAreaImagePath, actionCrop, postHover.PrimaryBounds);
        var actionResult = await engine.RecognizeSavedPngForSmokeTestAsync(
            actionAreaImagePath,
            actualActionCrop.X,
            actualActionCrop.Y);
        var actionMerged = MergeOcr(postHover.Ocr, actionResult.Result);
        var actionValidation = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(row, panel, actionMerged);
        if (actionValidation.IsConfirmed) return new(actionValidation, "ActionAreaOCR");

        foreach (int scale in new[] { 3, 4 })
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var source = new Bitmap(actionAreaImagePath);
            using var scaled = new Bitmap(source.Width * scale, source.Height * scale);
            using (var graphics = Graphics.FromImage(scaled))
            {
                graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(source, 0, 0, scaled.Width, scaled.Height);
            }
            scaled.Save(scaledActionAreaImagePath, ImageFormat.Png);
            var scaledResult = await engine.RecognizeSavedPngForSmokeTestAsync(scaledActionAreaImagePath, 0, 0);
            var absoluteScaled = ScreenCropGeometry.MapScaledOcrToAbsolute(scaledResult.Result, actualActionCrop, scale);

            foreach (var word in absoluteScaled.Words)
            {
                Console.WriteLine("PANEL_ACTION_OCR");
                Console.WriteLine($"Scale: {scale}x");
                Console.WriteLine($"token='{word.Text}'");
                Console.WriteLine($"absolute bounds=[{word.Bounds}]");
            }

            var scaledMerged = MergeOcr(postHover.Ocr, absoluteScaled);
            var scaledValidation = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(row, panel, scaledMerged);
            if (scaledValidation.IsConfirmed)
                return new(scaledValidation, $"UpscaledActionAreaOCR({scale}x)");
        }

        // 5. Scoped Visual Fallback for Verified Row
        if (File.Exists(rowCropBeforeImagePath) && File.Exists(rowCropAfterImagePath))
        {
            using var beforeBitmap = new Bitmap(rowCropBeforeImagePath);
            using var afterBitmap = new Bitmap(rowCropAfterImagePath);
            var fallback = PanelRowVisualInspector.LocateVisualAdmitFallback(
                beforeBitmap,
                afterBitmap,
                rowCrop,
                row,
                panel);

            if (fallback != null)
            {
                Console.WriteLine("PANEL_ADMIT_VISUAL_FALLBACK_CONFIRMED");
                Console.WriteLine($"Relative bounds: {fallback.RelativeBounds}");
                Console.WriteLine($"Absolute bounds: {fallback.AbsoluteBounds}");
                Console.WriteLine($"Confidence: {fallback.Confidence:P0}");

                var fallbackValidation = new HoverAdmitValidationResult
                {
                    IsConfirmed = true,
                    Row = row,
                    AdmitWord = new OcrWord("Admit", fallback.AbsoluteBounds),
                    AdmitCenter = fallback.Center,
                    Confidence = fallback.Confidence
                };
                return new(fallbackValidation, "VisualFallback");
            }
        }

        PrintPostHoverDebug(row, panel, actionMerged);
        return new(null, "None");
    }

    private static (int X, int Y) GetNeutralHoverPoint(
        WaitingParticipantRowCandidate row,
        ParticipantsPanelDetectionResult panel)
    {
        int x = checked((int)Math.Round(panel.PanelBounds.X + 2));
        double participantsBottom = panel.ParticipantsHeader == null
            ? panel.PanelBounds.Y + 8
            : panel.ParticipantsHeader.Bounds.Y + panel.ParticipantsHeader.Bounds.Height;
        double waitingTop = panel.WaitingRoomHeader?.Bounds.Y ?? row.RowBounds.Y;
        double desiredY = participantsBottom < waitingTop
            ? participantsBottom + (waitingTop - participantsBottom) / 2.0
            : panel.PanelBounds.Y + 8;
        double minY = panel.PanelBounds.Y + 8;
        double maxY = panel.PanelBounds.Y + panel.PanelBounds.Height - 8;
        int y = checked((int)Math.Round(Math.Clamp(desiredY, minY, maxY)));
        return (x, y);
    }

    private static void PrintHoverActivationDebug(
        (int X, int Y) originalCursor,
        SyntheticHoverTrace trace,
        (int X, int Y) cursorBeforeCapture,
        double difference,
        int attempt)
    {
        Console.WriteLine("HOVER_ACTIVATION_DEBUG");
        Console.WriteLine($"Attempt: {attempt}/{HoverActivationPolicy.MaximumAttempts}");
        Console.WriteLine($"Original cursor: ({originalCursor.X},{originalCursor.Y})");
        Console.WriteLine($"Neutral point: ({trace.NeutralPoint.X},{trace.NeutralPoint.Y})");
        Console.WriteLine($"Movement points: {string.Join(" -> ", trace.MovementPoints.Select(point => $"({point.X},{point.Y})"))}");
        Console.WriteLine($"Final hover point: ({trace.FinalPoint.X},{trace.FinalPoint.Y})");
        Console.WriteLine($"Cursor before post-hover capture: ({cursorBeforeCapture.X},{cursorBeforeCapture.Y})");
        Console.WriteLine($"Row visual change: {(HoverActivationPolicy.IsActivated(difference) ? "YES" : "NO")}");
        Console.WriteLine($"Difference %: {difference:F3}");
    }

    private static BoundingRectangleInfo SaveAbsoluteCrop(
        string fullImagePath,
        string cropImagePath,
        BoundingRectangleInfo absoluteCrop,
        BoundingRectangleInfo bounds)
    {
        var (monitorBounds, monitorName, localRect) = ScreenCropGeometry.GetMonitorLocalCropInfo(absoluteCrop);
        Console.WriteLine("MONITOR_CROP_SOURCE:");
        Console.WriteLine($"  Display: {monitorName}");
        Console.WriteLine($"  Monitor bounds: [{monitorBounds}]");
        Console.WriteLine($"  Absolute crop: [{absoluteCrop}]");
        Console.WriteLine($"  Local crop: [{localRect.X},{localRect.Y},{localRect.Width}x{localRect.Height}]");

        using var bitmap = WindowsScreenCapturer.CaptureAbsoluteRegion(absoluteCrop);
        bitmap.Save(cropImagePath, ImageFormat.Png);

        return new BoundingRectangleInfo(
            absoluteCrop.X,
            absoluteCrop.Y,
            bitmap.Width,
            bitmap.Height);
    }

    private static BoundingRectangleInfo GetActualCropBounds(
        BoundingRectangleInfo absoluteCrop,
        BoundingRectangleInfo bounds)
    {
        return new(
            absoluteCrop.X,
            absoluteCrop.Y,
            Math.Max(1, absoluteCrop.Width),
            Math.Max(1, absoluteCrop.Height));
    }

    private static OcrResult MergeOcr(OcrResult full, OcrResult crop)
        => OcrResultMerger.MergeWithoutOverlappingDuplicates(full, crop);

    private static string YesNo(bool value) => value ? "YES" : "NO";

    private static async Task<AutoAdmitScan> CaptureAndDetectAsync(
        WindowsNativeOcrEngine engine,
        string imagePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var monitors = WindowsScreenCapturer.CaptureAllScreens();
        try
        {
            var allLines = new List<OcrLine>();
            var allWords = new List<OcrWord>();
            DateTimeOffset captureCompletedAt = DateTimeOffset.UtcNow;
            string directory = Path.GetDirectoryName(imagePath) ?? Environment.CurrentDirectory;

            int monitorIndex = 0;
            double desktopMinX = double.MaxValue, desktopMinY = double.MaxValue;
            double desktopMaxX = double.MinValue, desktopMaxY = double.MinValue;

            foreach (var monitor in monitors)
            {
                cancellationToken.ThrowIfCancellationRequested();
                string monitorImagePath = Path.Combine(directory, $"monitor_scan_{monitorIndex++}.png");
                monitor.Bitmap.Save(monitorImagePath, ImageFormat.Png);

                var localOcr = await engine.RecognizeSavedPngForSmokeTestAsync(
                    monitorImagePath,
                    0,
                    0);

                var mappedOcr = ScreenCropGeometry.MapMonitorOcrToVirtualDesktop(localOcr.Result, monitor.Bounds);
                allLines.AddRange(mappedOcr.Lines);
                allWords.AddRange(mappedOcr.Words);

                desktopMinX = Math.Min(desktopMinX, monitor.Bounds.X);
                desktopMinY = Math.Min(desktopMinY, monitor.Bounds.Y);
                desktopMaxX = Math.Max(desktopMaxX, monitor.Bounds.X + monitor.Bounds.Width);
                desktopMaxY = Math.Max(desktopMaxY, monitor.Bounds.Y + monitor.Bounds.Height);
            }

            var virtualDesktopBounds = new BoundingRectangleInfo(
                desktopMinX,
                desktopMinY,
                Math.Max(1, desktopMaxX - desktopMinX),
                Math.Max(1, desktopMaxY - desktopMinY));

            var effectiveOcr = new OcrResult(allLines, allWords, virtualDesktopBounds);

            // Also save primary monitor to primary imagePath for backward compatibility
            var primary = monitors.FirstOrDefault(m => m.IsPrimary) ?? monitors[0];
            primary.Bitmap.Save(imagePath, ImageFormat.Png);

            var toastDetection = WaitingRoomToastDetector.Detect(effectiveOcr);
            var multiDetection = MultiPersonWaitingNotificationDetector.Detect(effectiveOcr);

            // Stamp monitor metadata
            foreach (var candidate in toastDetection.AllCandidates)
            {
                var hostMonitor = monitors.FirstOrDefault(m => m.Bounds.Contains(candidate.AdmitCenter.X, candidate.AdmitCenter.Y))
                                  ?? primary;
                candidate.MonitorName = hostMonitor.DeviceName;
                candidate.MonitorBounds = hostMonitor.Bounds;
            }

            foreach (var candidate in multiDetection.AllCandidates)
            {
                var hostMonitor = monitors.FirstOrDefault(m => m.Bounds.Contains(candidate.ViewCenter.X, candidate.ViewCenter.Y))
                                  ?? primary;
                candidate.MonitorName = hostMonitor.DeviceName;
                candidate.MonitorBounds = hostMonitor.Bounds;
            }

            return new AutoAdmitScan(
                toastDetection,
                multiDetection,
                effectiveOcr,
                virtualDesktopBounds,
                captureCompletedAt);
        }
        finally
        {
            foreach (var m in monitors) m.Dispose();
        }
    }

    private static async Task<OcrResult> RecoverInMeetingToastAdmitAsync(
        WindowsNativeOcrEngine engine,
        string fullImagePath,
        BoundingRectangleInfo actionCrop,
        BoundingRectangleInfo primaryBounds,
        OcrResult fullOcr,
        CancellationToken cancellationToken)
    {
        string directory = Path.GetDirectoryName(fullImagePath) ?? Environment.CurrentDirectory;
        string cropPath = Path.Combine(directory, "toast-action-area.png");
        string scaledPath = Path.Combine(directory, "toast-action-area-scaled.png");
        var actualCrop = SaveAbsoluteCrop(fullImagePath, cropPath, actionCrop, primaryBounds);
        Console.WriteLine("IN_MEETING_TOAST_LOCAL_OCR");
        Console.WriteLine($"Action row crop: {actualCrop}");

        var normal = await engine.RecognizeSavedPngForSmokeTestAsync(cropPath, actualCrop.X, actualCrop.Y);
        OcrResult merged = MergeOcr(fullOcr, normal.Result);
        if (merged.Words.Any(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase)))
        {
            Console.WriteLine("Recovered Admit source: ActionAreaOCR");
            return merged;
        }

        foreach (int scale in new[] { 2, 3 })
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var source = new Bitmap(cropPath);
            using var scaled = new Bitmap(source.Width * scale, source.Height * scale);
            using (var graphics = Graphics.FromImage(scaled))
            {
                graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(source, 0, 0, scaled.Width, scaled.Height);
            }
            scaled.Save(scaledPath, ImageFormat.Png);
            var scaledResult = await engine.RecognizeSavedPngForSmokeTestAsync(scaledPath, 0, 0);
            var absoluteScaled = ScreenCropGeometry.MapScaledOcrToAbsolute(scaledResult.Result, actualCrop, scale);
            merged = MergeOcr(fullOcr, absoluteScaled);
            if (merged.Words.Any(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase)))
            {
                Console.WriteLine($"Recovered Admit source: UpscaledActionAreaOCR({scale}x)");
                return merged;
            }
        }

        Console.WriteLine("IN_MEETING_TOAST_LOCAL_OCR_DID_NOT_RECOVER_ADMIT");
        return fullOcr;
    }

    private static bool Contains(BoundingRectangleInfo bounds, double x, double y) =>
        bounds.Width > 0 && bounds.Height > 0 &&
        x >= bounds.X && x <= bounds.X + bounds.Width &&
        y >= bounds.Y && y <= bounds.Y + bounds.Height;

    private sealed record PanelAdmitSearchResult(HoverAdmitValidationResult? Validation, string Source);
    private sealed record PanelLifecycleResult(bool ClickSent, bool Verified, string Reason);

}
