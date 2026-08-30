using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Ocr;

namespace ZoomAutoAdmit.UIAutomation.Input;

public static class ParticipantsPanelScrollRecovery
{
    public const int MaxScrollAttempts = 5;
    public const int DefaultWheelUpDelta = 120 * 4;
    public const int StepDelayMs = 150;

    public static async Task<AutoAdmitScan> RecoverWaitingRoomHeaderAsync(
        WindowsNativeOcrEngine engine,
        IMouseInput mouseInput,
        BoundingRectangleInfo panelBounds,
        string framePath,
        Func<double, double, bool> isLiveZoomSurface,
        Func<WindowsNativeOcrEngine, string, CancellationToken, Task<AutoAdmitScan>> captureFunc,
        CancellationToken cancellationToken)
    {
        int scrollX = checked((int)Math.Round(panelBounds.X + panelBounds.Width / 2.0));
        int scrollY = checked((int)Math.Round(panelBounds.Y + Math.Min(180.0, panelBounds.Height * 0.40)));

        if (!isLiveZoomSurface(scrollX, scrollY))
        {
            ConsoleLogger.Warn($"Scroll target ({scrollX},{scrollY}) is not a verified live Zoom surface.");
            return await captureFunc(engine, framePath, cancellationToken);
        }

        Console.WriteLine("PANEL_SCROLL_RECOVERY_STARTED");
        Console.WriteLine($"Panel bounds: {panelBounds}");
        Console.WriteLine($"Scroll target: ({scrollX},{scrollY})");

        AutoAdmitScan currentScan = await captureFunc(engine, framePath, cancellationToken);

        for (int attempt = 1; attempt <= MaxScrollAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            mouseInput.ScrollWheelPreservingCursor(scrollX, scrollY, DefaultWheelUpDelta);

            await Task.Delay(StepDelayMs, cancellationToken);

            currentScan = await captureFunc(engine, framePath, cancellationToken);

            var panel = WaitingRoomParticipantRowDetector.Detect(currentScan.Ocr);
            var admitAll = PanelAdmitAllDetector.Detect(currentScan.Ocr);

            bool waitingHeaderVisible = panel.WaitingRoomHeader != null;
            bool admitAllVisible = admitAll.IsAccepted;

            Console.WriteLine("PANEL_SCROLL_STEP");
            Console.WriteLine($"Attempt: {attempt}/{MaxScrollAttempts}");
            Console.WriteLine($"Waiting header visible: {(waitingHeaderVisible ? "YES" : "NO")}");
            Console.WriteLine($"Admit all visible: {(admitAllVisible ? "YES" : "NO")}");

            if (waitingHeaderVisible && admitAllVisible)
            {
                Console.WriteLine("PANEL_WAITING_HEADER_RECOVERED");
                Console.WriteLine("PANEL_ADMIT_ALL_DETECTED");
                break;
            }

            if (waitingHeaderVisible && panel.DeclaredWaitingCount == 1)
            {
                Console.WriteLine("PANEL_WAITING_HEADER_RECOVERED");
                break;
            }
        }

        return currentScan;
    }
}
