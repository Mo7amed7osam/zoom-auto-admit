using System.Drawing.Imaging;
using ZoomAutoAdmit.UIAutomation.Ocr;
using ZoomAutoAdmit.UIAutomation.Screen;

namespace ZoomAutoAdmit.Inspector.Commands;

public static class OcrSmokeCommand
{
    public static int Execute()
    {
        Console.WriteLine("OCR_SMOKE_START");
        Console.WriteLine("Detector invoked         : NO");
        Console.WriteLine("Capture count            : 1");

        var diagnosticsDirectory = Path.Combine(Environment.CurrentDirectory, "diagnostics");
        var imagePath = Path.Combine(diagnosticsDirectory, "current-ocr-frame.png");

        double originX;
        double originY;
        int captureWidth;
        int captureHeight;
        float dpiX;
        float dpiY;
        string capturePixelFormat;

        try
        {
            Directory.CreateDirectory(diagnosticsDirectory);
            var capture = WindowsScreenCapturer.CapturePrimaryScreen();
            using var bitmap = capture.Bitmap;

            originX = capture.ScreenBounds.X;
            originY = capture.ScreenBounds.Y;
            captureWidth = bitmap.Width;
            captureHeight = bitmap.Height;
            dpiX = capture.DpiX;
            dpiY = capture.DpiY;
            capturePixelFormat = bitmap.PixelFormat.ToString();

            // The OCR bridge below decodes this exact saved PNG, just as the old
            // working PowerShell implementation did.
            bitmap.Save(imagePath, ImageFormat.Png);
        }
        catch (Exception ex)
        {
            Console.WriteLine("CAPTURE_FAILED");
            PrintException(ex);
            return 2;
        }

        Console.WriteLine("CAPTURE_SUCCESS");
        Console.WriteLine("Capture source           : primary screen");
        Console.WriteLine($"Physical bounds X        : {originX:F0}");
        Console.WriteLine($"Physical bounds Y        : {originY:F0}");
        Console.WriteLine($"Physical bounds Width    : {captureWidth}");
        Console.WriteLine($"Physical bounds Height   : {captureHeight}");
        Console.WriteLine($"DPI X / Y                : {dpiX:F2} / {dpiY:F2}");
        Console.WriteLine($"Scale X / Y              : {dpiX / 96f:F3} / {dpiY / 96f:F3}");
        Console.WriteLine($"Capture bitmap size      : {captureWidth} x {captureHeight}");
        Console.WriteLine($"Capture pixel format     : {capturePixelFormat}");
        Console.WriteLine($"Saved OCR frame          : {Path.GetFullPath(imagePath)}");

        var engine = new WindowsNativeOcrEngine();
        if (!engine.IsAvailable)
        {
            Console.WriteLine("OCR_INITIALIZATION_FAILED");
            PrintException(engine.InitializationException ?? new InvalidOperationException("OcrEngine returned null."));
            return 3;
        }

        Console.WriteLine("OCR_INITIALIZATION_SUCCESS");
        Console.WriteLine($"OcrEngine language       : {engine.RecognizerLanguage}");
        Console.WriteLine($"OcrEngine.MaxImageDimension: {engine.MaxImageDimension}");

        try
        {
            var smoke = engine
                .RecognizeSavedPngForSmokeTestAsync(imagePath, originX, originY)
                .GetAwaiter()
                .GetResult();

            bool exceedsMaximum = smoke.BitmapWidth > engine.MaxImageDimension ||
                                  smoke.BitmapHeight > engine.MaxImageDimension;
            Console.WriteLine($"SoftwareBitmap size      : {smoke.BitmapWidth} x {smoke.BitmapHeight}");
            Console.WriteLine($"SoftwareBitmap format    : {smoke.PixelFormat}");
            Console.WriteLine($"SoftwareBitmap alpha     : {smoke.AlphaMode}");
            Console.WriteLine($"Exceeds max dimension    : {exceedsMaximum}");
            Console.WriteLine($"RecognizeAsync elapsed   : {smoke.RecognizeElapsed.TotalMilliseconds:F1} ms");
            Console.WriteLine($"OCR line count           : {smoke.Result.Lines.Count}");
            Console.WriteLine($"OCR word count           : {smoke.Result.Words.Count}");
            Console.WriteLine(smoke.Result.Words.Count == 0
                ? "OCR_SUCCESS_WITH_ZERO_WORDS"
                : "OCR_SUCCESS_WITH_WORDS");

            Console.WriteLine("--- COMPLETE OCR TEXT ---");
            Console.WriteLine(string.Join(Environment.NewLine, smoke.Result.Lines.Select(line => line.Text)));
            Console.WriteLine("--- END COMPLETE OCR TEXT ---");
            Console.WriteLine("--- EVERY WORD BOUNDING BOX ---");
            for (int index = 0; index < smoke.Result.Words.Count; index++)
            {
                var word = smoke.Result.Words[index];
                Console.WriteLine(
                    $"[{index + 1:D4}] '{word.Text}' " +
                    $"screen=(X={word.Bounds.X:F1}, Y={word.Bounds.Y:F1}, W={word.Bounds.Width:F1}, H={word.Bounds.Height:F1}) " +
                    $"image=(X={word.Bounds.X - originX:F1}, Y={word.Bounds.Y - originY:F1}, W={word.Bounds.Width:F1}, H={word.Bounds.Height:F1})");
            }
            Console.WriteLine("--- END EVERY WORD BOUNDING BOX ---");
            Console.WriteLine("OCR_SMOKE_COMPLETE");
            return 0;
        }
        catch (OcrRecognizeException ex)
        {
            Console.WriteLine("OCR_RECOGNIZE_FAILED");
            PrintException(ex);
            return 4;
        }
        catch (OcrBridgeException ex)
        {
            Console.WriteLine("OCR_BITMAP_BRIDGE_FAILED");
            PrintException(ex);
            return 5;
        }
        catch (Exception ex)
        {
            Console.WriteLine("OCR_RECOGNIZE_FAILED");
            PrintException(ex);
            return 6;
        }
    }

    private static void PrintException(Exception exception)
    {
        int depth = 0;
        for (Exception? current = exception; current != null; current = current.InnerException)
        {
            string prefix = depth == 0 ? "Exception" : $"Inner exception {depth}";
            Console.WriteLine($"{prefix} type          : {current.GetType().FullName}");
            Console.WriteLine($"{prefix} message       : {current.Message}");
            Console.WriteLine($"{prefix} HRESULT       : 0x{current.HResult:X8}");
            Console.WriteLine($"{prefix} stack trace   : {current.StackTrace ?? "(none)"}");
            depth++;
        }
    }
}
