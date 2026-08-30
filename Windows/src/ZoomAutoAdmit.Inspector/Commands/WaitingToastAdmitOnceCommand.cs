using System.Diagnostics;
using System.Drawing.Imaging;
using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Interop;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class WaitingToastAdmitOnceCommand
{
    private static readonly TimeSpan ConfirmationDelay = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan VerificationWindow = TimeSpan.FromSeconds(2.5);
    private static readonly TimeSpan VerificationPollDelay = TimeSpan.FromMilliseconds(150);

    public static int Execute(CliOptions options)
    {
        int timeoutSeconds = options.TimeoutExplicitlySet ? options.TimeoutSeconds : 60;

        Console.WriteLine("================================================================================");
        Console.WriteLine("WARNING:");
        Console.WriteLine("This command can admit exactly ONE participant from a verified Zoom Waiting Room toast.");
        Console.WriteLine("It sends one native mouse click only after three safe OCR captures.");
        Console.WriteLine("================================================================================");
        Console.WriteLine($"Watch timeout            : {timeoutSeconds} seconds");
        Console.WriteLine("Capture source           : Primary Screen");
        Console.WriteLine("Required confidence      : >= 95%");
        Console.WriteLine("Confirmation             : 2 matching frames + final fast frame");
        Console.WriteLine();

        var engine = new WindowsNativeOcrEngine();
        if (!engine.IsAvailable)
        {
            return AbortBeforeClick("OCR_INITIALIZATION_FAILED", engine.InitializationException);
        }

        string diagnosticsDirectory = Path.Combine(Environment.CurrentDirectory, "diagnostics");
        string framePath = Path.Combine(diagnosticsDirectory, "admit-once-current-frame.png");
        Directory.CreateDirectory(diagnosticsDirectory);

        var gate = new AdmitOnceSafetyGate();
        var clickExecutor = new SingleClickExecutor(new WindowsMouseInput());
        var totalWatch = Stopwatch.StartNew();
        DateTimeOffset? previousCandidateCapturedAt = null;

        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        bool userCancelled = false;
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            userCancelled = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;

        try
        {
            while (!cancellation.IsCancellationRequested && totalWatch.Elapsed < TimeSpan.FromSeconds(timeoutSeconds))
            {
                PrimaryToastScan scan;
                try
                {
                    scan = CaptureAndDetectAsync(engine, framePath, cancellation.Token).GetAwaiter().GetResult();
                }
                catch (Exception ex)
                {
                    if (FrameAcquisitionFailureClassifier.Classify(ex, cancellation.IsCancellationRequested) == FrameAcquisitionFailureKind.WatchTimeout)
                    {
                        return AbortExpected(userCancelled ? "USER_CANCELLED" : "WATCH_TIMEOUT");
                    }
                    return AbortBeforeClick("CAPTURE_OR_OCR_FAILED", ex);
                }

                var decision = gate.ObserveConfirmationFrame(
                    scan.Detection.AllCandidates,
                    scan.PrimaryBounds,
                    scan.Timestamp);

                PrintOcrSignalDiagnostics(scan, decision.Reason);

                if (decision.Candidate != null)
                {
                    PrintFrameTiming("CANDIDATE_FRAME", scan, previousCandidateCapturedAt);
                    previousCandidateCapturedAt = scan.CaptureCompletedAt;
                }

                if (decision.Kind == AdmitOnceDecisionKind.FirstFrameAccepted)
                {
                    PrintCandidate("FRAME_1_ACCEPTED", decision.Candidate!);
                    Thread.Sleep(ConfirmationDelay);
                    continue;
                }

                if (decision.Kind == AdmitOnceDecisionKind.Armed)
                {
                    PrintCandidate("FRAME_2_CONFIRMED", decision.Candidate!);
                    Console.WriteLine("Performing final fast pre-click capture...");
                    return ExecuteArmedClick(
                        engine,
                        framePath,
                        gate,
                        clickExecutor,
                        scan.PrimaryBounds,
                        scan.CaptureCompletedAt,
                        () => userCancelled,
                        cancellation.Token);
                }

                if (decision.Kind is AdmitOnceDecisionKind.DuplicateRejected)
                {
                    return AbortBeforeClick(decision.Reason);
                }

                Console.Write($"\rWatching... {totalWatch.Elapsed:mm\\:ss} | {decision.Reason}                    ");
                Thread.Sleep(ConfirmationDelay);
            }

            Console.WriteLine();
            return AbortExpected(userCancelled ? "USER_CANCELLED" : "WATCH_TIMEOUT");
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private static int ExecuteArmedClick(
        WindowsNativeOcrEngine engine,
        string framePath,
        AdmitOnceSafetyGate gate,
        SingleClickExecutor clickExecutor,
        BoundingRectangleInfo expectedPrimaryBounds,
        DateTimeOffset previousCandidateCapturedAt,
        Func<bool> isUserCancelled,
        CancellationToken cancellationToken)
    {
        PrimaryToastScan finalScan;
        try
        {
            finalScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            if (FrameAcquisitionFailureClassifier.Classify(ex, cancellationToken.IsCancellationRequested) == FrameAcquisitionFailureKind.WatchTimeout)
            {
                return AbortExpected(isUserCancelled() ? "USER_CANCELLED" : "WATCH_TIMEOUT");
            }
            return AbortBeforeClick("CAPTURE_OR_OCR_FAILED (final frame)", ex);
        }

        PrintFrameTiming("FINAL_FRAME_3", finalScan, previousCandidateCapturedAt);

        if (finalScan.PrimaryBounds != expectedPrimaryBounds)
        {
            return AbortBeforeClick("Primary Screen bounds changed between confirmation and final validation.");
        }

        bool interactiveDesktop = NativeMethods.IsInteractiveInputDesktopAvailable();
        var finalDecision = gate.ValidateFinalFrame(
            finalScan.Detection.AllCandidates,
            finalScan.PrimaryBounds,
            finalScan.Timestamp,
            interactiveDesktop);

        if (finalDecision.Kind != AdmitOnceDecisionKind.ClickReady || finalDecision.Candidate == null)
        {
            return AbortBeforeClick(finalDecision.Reason);
        }

        var candidate = finalDecision.Candidate;
        PrintCandidate("FINAL_FRAME_VALIDATED", candidate);

        var foregroundBefore = NativeMethods.GetForegroundWindowInfoSafe();
        string zoomStateBefore = GetZoomState(foregroundBefore);
        PrintForeground("Before click", foregroundBefore, zoomStateBefore);

        if (!gate.TryMarkClickSent(candidate, finalScan.Timestamp))
        {
            return AbortBeforeClick("The same command already marked a toast as clicked.");
        }

        int targetX = checked((int)Math.Round(candidate.AdmitCenter.X));
        int targetY = checked((int)Math.Round(candidate.AdmitCenter.Y));

        try
        {
            if (!clickExecutor.TryClick(targetX, targetY))
            {
                return AbortBeforeClick("Single-click guard rejected a second click attempt.");
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"Native click attempt failed: {ex}");
            Console.WriteLine("CLICK_SENT_BUT_NOT_VERIFIED");
            return 2;
        }

        Console.WriteLine("CLICK_SENT");
        Console.WriteLine($"Dynamic Admit target     : ({targetX}, {targetY})");

        var foregroundAfter = NativeMethods.GetForegroundWindowInfoSafe();
        string zoomStateAfter = GetZoomState(foregroundAfter);
        PrintForeground("After click", foregroundAfter, zoomStateAfter);
        Console.WriteLine($"Foreground changed       : {(foregroundBefore.Handle == foregroundAfter.Handle ? "NO" : "YES")}");

        var verificationDeadline = DateTimeOffset.UtcNow + VerificationWindow;
        AdmitOnceDecision? lastVerification = null;
        int consecutiveMissingFrames = 0;
        while (DateTimeOffset.UtcNow < verificationDeadline)
        {
            Thread.Sleep(VerificationPollDelay);
            try
            {
                var verificationScan = CaptureAndDetectAsync(engine, framePath, cancellationToken).GetAwaiter().GetResult();
                lastVerification = gate.ObserveVerificationFrame(
                    verificationScan.Detection.AllCandidates,
                    verificationScan.Timestamp,
                    verificationDeadline);

                if (lastVerification.Kind == AdmitOnceDecisionKind.Verified)
                {
                    consecutiveMissingFrames++;
                    if (consecutiveMissingFrames >= 2)
                    {
                        Console.WriteLine($"Verification             : {lastVerification.Reason} (confirmed in two consecutive captures)");
                        Console.WriteLine("ADMIT_VERIFIED");
                        return 0;
                    }
                }
                else
                {
                    consecutiveMissingFrames = 0;
                }
            }
            catch (Exception ex)
            {
                if (FrameAcquisitionFailureClassifier.Classify(ex, cancellationToken.IsCancellationRequested) == FrameAcquisitionFailureKind.WatchTimeout)
                {
                    break;
                }
                ConsoleLogger.Error($"Post-click verification capture failed: {ex}");
            }
        }

        Console.WriteLine($"Verification             : {lastVerification?.Reason ?? "No valid verification frame was available."}");
        Console.WriteLine("CLICK_SENT_BUT_NOT_VERIFIED");
        return 3;
    }

    private static async Task<PrimaryToastScan> CaptureAndDetectAsync(
        WindowsNativeOcrEngine engine,
        string framePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var captureStartedAt = DateTimeOffset.UtcNow;
        var totalStopwatch = Stopwatch.StartNew();
        var phaseStopwatch = Stopwatch.StartNew();
        var capture = WindowsScreenCapturer.CapturePrimaryScreen();
        using (capture.Bitmap)
        {
            capture.Bitmap.Save(framePath, ImageFormat.Png);
        }
        phaseStopwatch.Stop();
        var captureElapsed = phaseStopwatch.Elapsed;
        var captureCompletedAt = DateTimeOffset.UtcNow;

        var ocrStartedAt = DateTimeOffset.UtcNow;
        phaseStopwatch.Restart();
        var smoke = await engine.RecognizeSavedPngForSmokeTestAsync(
            framePath,
            capture.ScreenBounds.X,
            capture.ScreenBounds.Y);
        phaseStopwatch.Stop();
        var ocrElapsed = phaseStopwatch.Elapsed;
        var ocrCompletedAt = DateTimeOffset.UtcNow;
        cancellationToken.ThrowIfCancellationRequested();

        phaseStopwatch.Restart();
        var detection = WaitingRoomToastDetector.Detect(smoke.Result);
        phaseStopwatch.Stop();
        var detectorElapsed = phaseStopwatch.Elapsed;
        var detectionCompletedAt = DateTimeOffset.UtcNow;
        totalStopwatch.Stop();
        detection.ScanDuration = totalStopwatch.Elapsed;
        return new PrimaryToastScan(
            detection,
            smoke.Result,
            capture.ScreenBounds,
            captureStartedAt,
            captureCompletedAt,
            ocrStartedAt,
            ocrCompletedAt,
            detectionCompletedAt,
            captureElapsed,
            ocrElapsed,
            detectorElapsed,
            totalStopwatch.Elapsed);
    }

    private static string GetZoomState(ForegroundWindowInfo foreground)
    {
        var candidates = new ZoomProcessDiscovery().FindCandidates(logInfo: false);
        if (candidates.Count == 0)
        {
            return "MINIMIZED (Zoom process/window not observable)";
        }

        if (candidates.Any(candidate => candidate.ProcessId == foreground.ProcessId))
        {
            return "FOREGROUND";
        }

        bool anyVisibleWindow = candidates.Any(candidate =>
            candidate.Windows.Any(window => window.IsVisible && window.Bounds.Width > 0 && window.Bounds.Height > 0));
        return anyVisibleWindow ? "BACKGROUND" : "MINIMIZED";
    }

    private static void PrintForeground(string label, ForegroundWindowInfo info, string zoomState)
    {
        Console.WriteLine($"{label} HWND          : 0x{info.Handle.ToInt64():X}");
        Console.WriteLine($"{label} process       : {info.ProcessName} (PID {info.ProcessId})");
        Console.WriteLine($"{label} Zoom state    : {zoomState}");
    }

    private static void PrintCandidate(string label, WaitingRoomToastCandidate candidate)
    {
        var identity = WaitingRoomParticipantIdentity.FromAcceptedCandidateText(candidate.ParticipantName);
        Console.WriteLine();
        Console.WriteLine(label);
        Console.WriteLine($"Raw participant text     : {identity.RawText}");
        Console.WriteLine($"Participant              : {identity.NormalizedName}");
        Console.WriteLine($"Confidence               : {candidate.Confidence:P0}");
        Console.WriteLine($"Toast bounds             : {candidate.ToastBounds}");
        Console.WriteLine($"Admit bounds             : {candidate.AdmitWord!.Bounds}");
        Console.WriteLine($"View bounds              : {candidate.ViewWord!.Bounds}");
        Console.WriteLine($"Dynamic Admit center     : ({candidate.AdmitCenter.X:F1}, {candidate.AdmitCenter.Y:F1})");
    }

    private static void PrintOcrSignalDiagnostics(PrimaryToastScan scan, string actionFilterReason)
    {
        bool enteredThe = scan.Ocr.Lines.Any(line =>
            Regex.IsMatch(line.Text, @"\b(?:has\s+)?entered\s+the\b", RegexOptions.IgnoreCase));
        bool waitingRoom = scan.Ocr.Lines.Any(line =>
            Regex.IsMatch(line.Text, @"\bwaiting\s+room\b", RegexOptions.IgnoreCase));
        bool admitExact = scan.Ocr.Words.Any(word =>
            word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase));
        bool viewExact = scan.Ocr.Words.Any(word =>
            word.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase));

        if (!enteredThe && !waitingRoom && !admitExact && !viewExact)
        {
            return;
        }

        Console.WriteLine();
        Console.WriteLine("OCR SIGNALS:");
        Console.WriteLine($"entered-the line         : {(enteredThe ? "YES" : "NO")}");
        Console.WriteLine($"waiting-room line        : {(waitingRoom ? "YES" : "NO")}");
        Console.WriteLine($"Admit exact              : {(admitExact ? "YES" : "NO")}");
        Console.WriteLine($"View exact               : {(viewExact ? "YES" : "NO")}");
        Console.WriteLine("Candidates:");
        Console.WriteLine($"Admit count              : {scan.Detection.AllAdmitWordsFound.Count}");
        Console.WriteLine($"View count               : {scan.Detection.AllViewWordsFound.Count}");
        Console.WriteLine($"Waiting header count     : {scan.Detection.AllWaitingRoomLinesFound.Count}");

        if (scan.Detection.AllCandidates.Count == 0)
        {
            Console.WriteLine("Candidate rejected because: no Admit candidate was constructed.");
            return;
        }

        for (int index = 0; index < scan.Detection.AllCandidates.Count; index++)
        {
            var candidate = scan.Detection.AllCandidates[index];
            var identity = WaitingRoomParticipantIdentity.FromAcceptedCandidateText(candidate.ParticipantName);
            Console.WriteLine($"Candidate #{index + 1} confidence: {candidate.Confidence:P0} (before >=95% action filter)");
            Console.WriteLine($"Candidate #{index + 1} detector accepted: {(candidate.IsAccepted ? "YES" : "NO")}");
            Console.WriteLine($"Candidate #{index + 1} raw participant: '{identity.RawText}'");
            Console.WriteLine($"Candidate #{index + 1} normalized participant: '{identity.NormalizedName}'");
            if (candidate.RejectionReasons.Count == 0)
            {
                Console.WriteLine($"Candidate #{index + 1} detector rejection: (none)");
            }
            else
            {
                foreach (var reason in candidate.RejectionReasons)
                {
                    Console.WriteLine($"Candidate #{index + 1} rejected because: {reason}");
                }
            }

            var actionReasons = AdmitOnceSafetyGate.GetActionFilterRejectionReasons(candidate);
            if (actionReasons.Count == 0)
            {
                Console.WriteLine($"Candidate #{index + 1} action filter: PASSED ({actionFilterReason})");
            }
            else
            {
                foreach (var reason in actionReasons)
                {
                    Console.WriteLine($"Candidate #{index + 1} action rejected because: {reason}");
                }
            }
        }
    }

    private static void PrintFrameTiming(
        string label,
        PrimaryToastScan scan,
        DateTimeOffset? previousCapturedAt)
    {
        Console.WriteLine();
        Console.WriteLine($"{label}_TIMING");
        Console.WriteLine($"Capture started-at       : {scan.CaptureStartedAt:O}");
        Console.WriteLine($"Capture completed-at     : {scan.CaptureCompletedAt:O}");
        Console.WriteLine($"OCR started-at           : {scan.OcrStartedAt:O}");
        Console.WriteLine($"OCR completed-at         : {scan.OcrCompletedAt:O}");
        Console.WriteLine($"Detection completed-at   : {scan.DetectionCompletedAt:O}");
        Console.WriteLine($"Capture ms               : {scan.CaptureElapsed.TotalMilliseconds:F1}");
        Console.WriteLine($"OCR ms                   : {scan.OcrElapsed.TotalMilliseconds:F1}");
        Console.WriteLine($"Detector ms              : {scan.DetectorElapsed.TotalMilliseconds:F1}");
        Console.WriteLine($"Total frame ms           : {scan.TotalElapsed.TotalMilliseconds:F1}");
        Console.WriteLine($"Frame captured-at        : {scan.CaptureCompletedAt:O}");
        Console.WriteLine($"Previous captured-at     : {(previousCapturedAt.HasValue ? previousCapturedAt.Value.ToString("O") : "(none)")}");
        Console.WriteLine($"Frame-to-frame delta     : {(previousCapturedAt.HasValue ? (scan.CaptureCompletedAt - previousCapturedAt.Value).TotalMilliseconds.ToString("F1") + " ms" : "(first frame)")}");
    }

    private static int AbortBeforeClick(string reason, Exception? exception = null)
    {
        Console.WriteLine();
        ConsoleLogger.Error($"Aborted before click: {reason}");
        if (exception != null)
        {
            ConsoleLogger.Error(exception.ToString());
        }
        Console.WriteLine("ABORTED_BEFORE_CLICK");
        return 1;
    }

    private static int AbortExpected(string reason)
    {
        Console.WriteLine();
        Console.WriteLine("ABORTED_BEFORE_CLICK");
        Console.WriteLine($"Reason: {reason}");
        return 1;
    }

    private sealed record PrimaryToastScan(
        WaitingRoomToastDetectionResult Detection,
        OcrResult Ocr,
        BoundingRectangleInfo PrimaryBounds,
        DateTimeOffset CaptureStartedAt,
        DateTimeOffset CaptureCompletedAt,
        DateTimeOffset OcrStartedAt,
        DateTimeOffset OcrCompletedAt,
        DateTimeOffset DetectionCompletedAt,
        TimeSpan CaptureElapsed,
        TimeSpan OcrElapsed,
        TimeSpan DetectorElapsed,
        TimeSpan TotalElapsed)
    {
        public DateTimeOffset Timestamp => CaptureCompletedAt;
    }
}
