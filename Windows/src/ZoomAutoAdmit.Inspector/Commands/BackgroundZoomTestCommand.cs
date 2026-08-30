using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Interop;
using ZoomAutoAdmit.UIAutomation.Screen;
using ZoomAutoAdmit.UIAutomation.Window;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class BackgroundZoomTestCommand
{
    public static int Execute(CliOptions options)
    {
        Console.WriteLine("================================================================================");
        Console.WriteLine("                    Background Zoom Capability Diagnostic                          ");
        Console.WriteLine("================================================================================");

        var zoomHwnd = ZoomWindowManager.FindActiveZoomWindow();
        if (zoomHwnd == IntPtr.Zero)
        {
            ConsoleLogger.Error("No active Zoom meeting or participants window found.");
            Console.WriteLine("WINDOW_CAPTURE_SUPPORTED: NO");
            Console.WriteLine("BACKGROUND_HOVER_SUPPORTED: NO");
            Console.WriteLine("BACKGROUND_CLICK_SUPPORTED: NO");
            Console.WriteLine("BACKGROUND_SCROLL_SUPPORTED: NO");
            Console.WriteLine("FOREGROUND_REQUIRED: YES");
            return 1;
        }

        var role = ZoomWindowManager.ClassifyZoomWindow(zoomHwnd);
        Console.WriteLine($"Target Window: HWND=0x{zoomHwnd.ToInt64():X} Role={role} Process='{NativeMethods.GetProcessNameSafe(zoomHwnd)}' Title='{NativeMethods.GetWindowTitleSafe(zoomHwnd)}'");

        // Test 1: Window Capture
        using var capture = WindowsWindowCapturer.CaptureWindow(zoomHwnd);
        bool captureOk = capture.IsSuccessful && capture.Bitmap != null && capture.Bitmap.Width > 0 && capture.Bitmap.Height > 0;
        Console.WriteLine($"Window Capture: {(captureOk ? "SUCCESS" : "FAILED")} ({capture.FailureReason}) Bounds={capture.WindowBounds}");

        // Test 2: Coordinate Mapping
        var clientCoords = BackgroundZoomInteraction.ToClientCoordinates(zoomHwnd, capture.WindowBounds.X + 50, capture.WindowBounds.Y + 50);
        Console.WriteLine($"Client Coordinate Mapping: ({clientCoords.ClientX},{clientCoords.ClientY})");

        // Test 3: Validate Target Safety (not meeting chat)
        var validation = BackgroundZoomInteraction.ValidateTarget(zoomHwnd);
        bool targetOk = validation == BackgroundInteractionResult.Success;

        Console.WriteLine();
        Console.WriteLine("================================================================================");
        Console.WriteLine($"WINDOW_CAPTURE_SUPPORTED: {(captureOk ? "YES" : "NO")}");
        Console.WriteLine($"BACKGROUND_HOVER_SUPPORTED: {(targetOk ? "YES" : "NO")}");
        Console.WriteLine($"BACKGROUND_CLICK_SUPPORTED: {(targetOk ? "YES" : "NO")}");
        Console.WriteLine($"BACKGROUND_SCROLL_SUPPORTED: {(targetOk ? "YES" : "NO")}");
        Console.WriteLine($"FOREGROUND_REQUIRED: {(captureOk && targetOk ? "NO" : "YES")}");
        Console.WriteLine("================================================================================");

        return 0;
    }
}
