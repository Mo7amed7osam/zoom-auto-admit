using System.Drawing.Imaging;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Input;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class WaitingRowHoverWatchCommand
{
    private const double MinimumRowConfidence = 0.90;
    private static readonly TimeSpan HoverRenderDelay = TimeSpan.FromMilliseconds(200);

    public static int Execute(CliOptions options)
    {
        int timeoutSeconds = options.TimeoutExplicitlySet ? options.TimeoutSeconds : 60;
        Console.WriteLine("================================================================================");
        Console.WriteLine("Participants Waiting Room Row Hover Diagnostic (NO CLICKS)");
        Console.WriteLine("This command may move the cursor temporarily, but it never sends mouse clicks.");
        Console.WriteLine("Capture: Primary Screen -> PNG -> Windows.Media.Ocr");
        Console.WriteLine($"Timeout: {timeoutSeconds} seconds");
        Console.WriteLine("================================================================================");

        var ocrEngine = new WindowsNativeOcrEngine();
        if (!ocrEngine.IsAvailable)
        {
            ConsoleLogger.Error("OCR_INITIALIZATION_FAILED");
            return 1;
        }

        string diagnosticsDirectory = Path.Combine(Environment.CurrentDirectory, "diagnostics");
        Directory.CreateDirectory(diagnosticsDirectory);
        string beforePath = Path.Combine(diagnosticsDirectory, "waiting-row-before-hover.png");
        string afterPath = Path.Combine(diagnosticsDirectory, "waiting-row-after-hover.png");

        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(timeoutSeconds);
        bool panelEverVisible = false;

        while (DateTimeOffset.UtcNow < deadline && !cancellation.IsCancellationRequested)
        {
            PanelOcrFrame frame;
            try
            {
                frame = CaptureOcrFrameAsync(ocrEngine, beforePath, cancellation.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                ConsoleLogger.Error($"CAPTURE_OR_OCR_FAILED: {ex}");
                return 1;
            }

            var panel = WaitingRoomParticipantRowDetector.Detect(frame.Ocr);
            if (!panel.IsPanelVisible)
            {
                Console.Write("\rPARTICIPANTS_PANEL_NOT_VISIBLE — waiting for visible Zoom Participants panel...          ");
                Thread.Sleep(250);
                continue;
            }

            panelEverVisible = true;
            PrintPanel(panel);
            var selectedRow = panel.Rows
                .Where(row => row.Confidence >= MinimumRowConfidence)
                .OrderBy(row => row.RowBounds.Y)
                .FirstOrDefault();
            if (selectedRow == null)
            {
                Console.WriteLine("No high-confidence Waiting Room participant row is currently visible.");
                Thread.Sleep(250);
                continue;
            }

            int hoverX = checked((int)Math.Round(selectedRow.SafeHoverPoint.X));
            int hoverY = checked((int)Math.Round(selectedRow.SafeHoverPoint.Y));
            Console.WriteLine($"Selected topmost row     : {selectedRow.ParticipantName}");
            Console.WriteLine($"Safe hover point         : ({hoverX}, {hoverY})");
            Console.WriteLine("Moving cursor for hover only — NO CLICK...");

            PanelOcrFrame postHoverFrame;
            try
            {
                var hover = new CursorPreservingHover(new WindowsCursorController());
                postHoverFrame = hover.Run(hoverX, hoverY, () =>
                {
                    Thread.Sleep(HoverRenderDelay);
                    return CaptureOcrFrameAsync(ocrEngine, afterPath, cancellation.Token).GetAwaiter().GetResult();
                });
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                Console.WriteLine("HOVER_NOT_CONFIRMED: WATCH_TIMEOUT");
                return 1;
            }
            catch (Exception ex)
            {
                ConsoleLogger.Error($"Hover diagnostic failed; cursor restoration was attempted: {ex}");
                return 1;
            }

            var validation = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(
                selectedRow,
                panel,
                postHoverFrame.Ocr);
            if (!validation.IsConfirmed || validation.AdmitWord == null || validation.Row == null)
            {
                Console.WriteLine("HOVER_NOT_CONFIRMED");
                foreach (var reason in validation.RejectionReasons)
                {
                    Console.WriteLine($"  - {reason}");
                }
                return 2;
            }

            Console.WriteLine();
            Console.WriteLine("HOVER_CONFIRMED");
            Console.WriteLine($"Participant              : {validation.Row.ParticipantName}");
            Console.WriteLine($"Row                      : {validation.Row.RowBounds}");
            Console.WriteLine($"Admit                    : {validation.AdmitWord.Bounds}");
            Console.WriteLine($"Dynamic Admit center     : ({validation.AdmitCenter.X:F1}, {validation.AdmitCenter.Y:F1})");
            Console.WriteLine($"Confidence               : {validation.Confidence:P0}");
            Console.WriteLine("Cursor restored. No click was sent.");
            return 0;
        }

        Console.WriteLine();
        Console.WriteLine(panelEverVisible ? "WAITING_ROOM_ROW_NOT_FOUND" : "PARTICIPANTS_PANEL_NOT_VISIBLE");
        return 1;
    }

    private static async Task<PanelOcrFrame> CaptureOcrFrameAsync(
        WindowsNativeOcrEngine engine,
        string imagePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capture = WindowsScreenCapturer.CapturePrimaryScreen();
        using (capture.Bitmap)
        {
            capture.Bitmap.Save(imagePath, ImageFormat.Png);
        }

        var result = await engine.RecognizeSavedPngForSmokeTestAsync(
            imagePath,
            capture.ScreenBounds.X,
            capture.ScreenBounds.Y);
        cancellationToken.ThrowIfCancellationRequested();
        return new PanelOcrFrame(result.Result, capture.ScreenBounds);
    }

    private static void PrintPanel(ParticipantsPanelDetectionResult panel)
    {
        Console.WriteLine();
        Console.WriteLine("PARTICIPANTS_PANEL_VISIBLE");
        Console.WriteLine($"Participants header      : {panel.ParticipantsHeader?.Bounds}");
        Console.WriteLine($"Waiting room header      : {panel.WaitingRoomHeader?.Bounds}");
        Console.WriteLine($"Joined header            : {(panel.JoinedHeader != null ? panel.JoinedHeader.Bounds.ToString() : "(not found)")}");
        Console.WriteLine($"Rows found               : {panel.Rows.Count}");
        foreach (var row in panel.Rows)
        {
            Console.WriteLine($"  Participant            : {row.ParticipantName}");
            Console.WriteLine($"  Row bounds             : {row.RowBounds}");
            Console.WriteLine($"  Waiting header bounds  : {panel.WaitingRoomHeader?.Bounds}");
            Console.WriteLine($"  Joined header bounds   : {(panel.JoinedHeader != null ? panel.JoinedHeader.Bounds.ToString() : "(not found)")}");
            Console.WriteLine($"  Confidence             : {row.Confidence:P0}");
        }
    }

    private sealed record PanelOcrFrame(OcrResult Ocr, BoundingRectangleInfo PrimaryBounds);
}
