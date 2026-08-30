using System.Diagnostics;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Inspection;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class WaitingToastWatchCommand
{
    public static int Execute(CliOptions options)
    {
        int timeoutSec = options.TimeoutExplicitlySet ? options.TimeoutSeconds : 60;

        Console.WriteLine("================================================================================");
        Console.WriteLine("          Zoom Waiting Room Toast Visual Localization & Watcher                 ");
        Console.WriteLine("================================================================================");
        Console.WriteLine($"Mode           : Windows Native OCR + Spatial Triangulation (READ-ONLY)");
        Console.WriteLine($"Watch Duration : {timeoutSec} seconds");
        Console.WriteLine($"Poll Interval  : ~500ms");
        Console.WriteLine();
        Console.WriteLine("Detection Strategy:");
        Console.WriteLine("  1. Native Windows OCR of virtual desktop (Per-Monitor DPI aware).");
        Console.WriteLine("  2. Spatial triangulation: <Participant> entered waiting room + [Admit] + [View].");
        Console.WriteLine("  3. Validates button alignment, spacing, header proximity, and rejects code context.");
        Console.WriteLine("  4. Calculates dynamic Admit center coordinates for reliable targeting.");
        Console.WriteLine();
        Console.WriteLine("Instructions:");
        Console.WriteLine("  1. Start a Zoom meeting as host.");
        Console.WriteLine("  2. Test with Zoom in Foreground, Background (e.g. VS Code/Browser focused), or Minimized.");
        Console.WriteLine("  3. Have a participant join the Waiting Room to trigger the native Zoom toast.");
        Console.WriteLine("  4. Press Ctrl+C at any time to stop.");
        Console.WriteLine("================================================================================");
        Console.WriteLine();

        var locator = new WaitingRoomToastLocator();
        if (!locator.IsOcrAvailable)
        {
            ConsoleLogger.Error("Windows.Media.Ocr.OcrEngine is unavailable. Ensure Windows 10/11 OCR language packs are installed.");
            return 1;
        }

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSec));
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
            ConsoleLogger.Warn("\nWatch cancelled by user.");
        };

        var sw = Stopwatch.StartNew();
        int tickCount = 0;
        int detectionCount = 0;
        string? lastDetectedParticipant = null;

        ConsoleLogger.Info($"Starting Waiting Room Toast Watcher (Timeout: {timeoutSec}s)...");

        while (!cts.Token.IsCancellationRequested && sw.Elapsed.TotalSeconds < timeoutSec)
        {
            tickCount++;
            var remainingSec = Math.Max(0, timeoutSec - (int)sw.Elapsed.TotalSeconds);

            // Check Zoom Process & Foreground Window State
            var fg = NativeMethods.GetForegroundWindowInfoSafe();
            var zoomDiscovery = new ZoomProcessDiscovery();
            var zoomCandidates = zoomDiscovery.FindCandidates(logInfo: false);
            var meetingCandidate = zoomCandidates.FirstOrDefault(z =>
                z.MainWindowTitle.Contains("Zoom Meeting", StringComparison.OrdinalIgnoreCase) ||
                z.MainWindowTitle.Contains("Zoom Workplace", StringComparison.OrdinalIgnoreCase) ||
                z.Windows.Any(w => w.Title.Contains("Meeting", StringComparison.OrdinalIgnoreCase)) ||
                z.ProcessName.Contains("Zoom", StringComparison.OrdinalIgnoreCase));

            string zoomStatus;
            if (meetingCandidate == null)
            {
                zoomStatus = "Zoom process not detected";
            }
            else if (fg.ProcessId == meetingCandidate.ProcessId)
            {
                zoomStatus = $"Zoom FOREGROUND (PID: {meetingCandidate.ProcessId}, Title: '{meetingCandidate.MainWindowTitle}')";
            }
            else
            {
                var visibleWindow = meetingCandidate.Windows.FirstOrDefault(w => w.IsVisible && w.Bounds.Width > 0 && w.Bounds.Height > 0);
                if (visibleWindow != null)
                {
                    zoomStatus = $"Zoom BACKGROUND (PID: {meetingCandidate.ProcessId}, Foreground: [{fg.ProcessName}] '{fg.WindowTitle}')";
                }
                else
                {
                    zoomStatus = $"Zoom MINIMIZED / HIDDEN (PID: {meetingCandidate.ProcessId}, Foreground: [{fg.ProcessName}] '{fg.WindowTitle}')";
                }
            }

            // Run Screen Capture & Native OCR Scan
            var result = locator.ScanDesktopAsync(cts.Token).GetAwaiter().GetResult();

            if (result.IsDetected && result.BestCandidate != null)
            {
                detectionCount++;
                var best = result.BestCandidate;
                var participant = best.ParticipantName ?? "(Unknown Participant)";

                Console.WriteLine();
                ConsoleLogger.Success($"[MATCH #{detectionCount} @ {sw.Elapsed:mm\\:ss}] Zoom Waiting Room Toast Detected!");
                Console.WriteLine("--------------------------------------------------------------------------------");
                Console.WriteLine($"  Participant Name     : {participant}");
                Console.WriteLine($"  Toast Bounds         : X={best.ToastBounds.X:F0}, Y={best.ToastBounds.Y:F0}, W={best.ToastBounds.Width:F0}, H={best.ToastBounds.Height:F0}");
                if (best.AdmitWord != null)
                {
                    Console.WriteLine($"  Admit OCR Box        : X={best.AdmitWord.Bounds.X:F0}, Y={best.AdmitWord.Bounds.Y:F0}, W={best.AdmitWord.Bounds.Width:F0}, H={best.AdmitWord.Bounds.Height:F0}");
                }
                if (best.ViewWord != null)
                {
                    Console.WriteLine($"  View OCR Box         : X={best.ViewWord.Bounds.X:F0}, Y={best.ViewWord.Bounds.Y:F0}, W={best.ViewWord.Bounds.Width:F0}, H={best.ViewWord.Bounds.Height:F0}");
                }
                Console.WriteLine($"  Calculated Admit Center: ({best.AdmitCenter.X:F0}, {best.AdmitCenter.Y:F0})");
                Console.WriteLine($"  Confidence           : {best.Confidence:P0}");
                Console.WriteLine($"  Zoom Window State    : {zoomStatus}");
                Console.WriteLine($"  Scan Latency         : {result.ScanDuration.TotalMilliseconds:F0}ms");
                Console.WriteLine();
                Console.WriteLine("  Validation Reasons:");
                foreach (var reason in best.AcceptanceReasons)
                {
                    Console.WriteLine($"    [+] {reason}");
                }

                if (result.AllCandidates.Count > 1)
                {
                    Console.WriteLine();
                    Console.WriteLine("  Other Candidate Evaluations (False-Positive Protection):");
                    foreach (var cand in result.AllCandidates.Where(c => c != best))
                    {
                        var admitPos = cand.AdmitWord != null ? $"X={cand.AdmitWord.Bounds.X:F0}, Y={cand.AdmitWord.Bounds.Y:F0}" : "none";
                        Console.WriteLine($"    [-] Candidate at ({admitPos}):");
                        foreach (var rej in cand.RejectionReasons)
                        {
                            Console.WriteLine($"        * REJECTED: {rej}");
                        }
                    }
                }
                Console.WriteLine("--------------------------------------------------------------------------------");

                lastDetectedParticipant = participant;
            }
            else if (result.AllCandidates.Count > 0)
            {
                // Candidates were found (e.g. the word "Admit" in VS Code/terminal) but all rejected
                var firstRejection = result.AllCandidates.First();
                var rejectSummary = firstRejection.RejectionReasons.FirstOrDefault() ?? "Did not satisfy spatial toast constraints";
                Console.Write($"\r[{sw.Elapsed:mm\\:ss} | {remainingSec}s left] Scanning... Found {result.AllCandidates.Count} candidate(s) (All Rejected: {rejectSummary}) | {zoomStatus.Split('(')[0].Trim()}   ");
            }
            else
            {
                Console.Write($"\r[{sw.Elapsed:mm\\:ss} | {remainingSec}s left] Watching for Waiting Room toast... (Scan: {result.ScanDuration.TotalMilliseconds:F0}ms) | {zoomStatus.Split('(')[0].Trim()}   ");
            }

            try
            {
                Thread.Sleep(500);
            }
            catch { }
        }

        Console.WriteLine();
        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine("                       Watch Summary Report                             ");
        Console.WriteLine("================================================================================");
        Console.WriteLine($"Total Elapsed Time     : {sw.Elapsed.TotalSeconds:F1}s");
        Console.WriteLine($"Total Scans Executed   : {tickCount}");
        Console.WriteLine($"Valid Detections       : {detectionCount}");
        if (detectionCount > 0)
        {
            ConsoleLogger.Success($"Successfully localized native Waiting Room toast ({detectionCount} detection frames)!");
            if (lastDetectedParticipant != null)
            {
                Console.WriteLine($"Last Participant       : {lastDetectedParticipant}");
            }
        }
        else
        {
            ConsoleLogger.Warn("No valid Waiting Room toast detected during this watch session.");
        }
        Console.WriteLine("================================================================================");

        return 0;
    }
}
