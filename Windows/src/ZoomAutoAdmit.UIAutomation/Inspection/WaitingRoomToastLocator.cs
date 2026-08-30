using System.Diagnostics;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

/// <summary>
/// Coordinates desktop screen capture, native Windows OCR, and spatial toast detection.
/// </summary>
public class WaitingRoomToastLocator
{
    private readonly WindowsNativeOcrEngine _ocrEngine;

    public WaitingRoomToastLocator()
    {
        _ocrEngine = new WindowsNativeOcrEngine();
    }

    public bool IsOcrAvailable => _ocrEngine.IsAvailable;

    /// <summary>
    /// Captures the current desktop and scans for the Zoom Waiting Room toast.
    /// </summary>
    public async Task<WaitingRoomToastDetectionResult> ScanDesktopAsync(CancellationToken cancellationToken = default)
    {
        var sw = Stopwatch.StartNew();

        if (!_ocrEngine.IsAvailable)
        {
            throw new InvalidOperationException("OCR_INITIALIZATION_FAILED", _ocrEngine.InitializationException);
        }

        try
        {
            var (bitmap, screenBounds) = WindowsScreenCapturer.CaptureDesktop();
            using (bitmap)
            {
                var ocrResult = await _ocrEngine.RecognizeBitmapAsync(bitmap, screenBounds.X, screenBounds.Y);
                var detectionResult = WaitingRoomToastDetector.Detect(ocrResult);
                detectionResult.ScanDuration = sw.Elapsed;
                return detectionResult;
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"CAPTURE_OR_OCR_FAILED: {ex}");
            throw;
        }
    }

    /// <summary>
    /// Scans a saved image file for Zoom Waiting Room toast (useful for diagnostic replay and testing).
    /// </summary>
    public async Task<WaitingRoomToastDetectionResult> ScanImageFileAsync(string imagePath, CancellationToken cancellationToken = default)
    {
        var sw = Stopwatch.StartNew();

        if (!_ocrEngine.IsAvailable)
        {
            throw new InvalidOperationException("OCR_INITIALIZATION_FAILED", _ocrEngine.InitializationException);
        }

        try
        {
            var ocrResult = await _ocrEngine.RecognizeImageFileAsync(imagePath, cancellationToken);
            var detectionResult = WaitingRoomToastDetector.Detect(ocrResult);
            detectionResult.ScanDuration = sw.Elapsed;
            return detectionResult;
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"OCR_IMAGE_SCAN_FAILED: {ex}");
            throw;
        }
    }
}
