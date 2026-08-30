using System.Drawing;
using System.Drawing.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using CoreOcrResult = ZoomAutoAdmit.Core.Models.OcrResult;
using CoreOcrLine = ZoomAutoAdmit.Core.Models.OcrLine;
using CoreOcrWord = ZoomAutoAdmit.Core.Models.OcrWord;

namespace ZoomAutoAdmit.UIAutomation.Ocr;

/// <summary>
/// Native Windows OCR adapter using Windows.Media.Ocr.OcrEngine.
/// </summary>
public class WindowsNativeOcrEngine : IOcrEngine
{
    private readonly OcrEngine? _engine;

    public Exception? InitializationException { get; }

    public bool IsAvailable => _engine != null;
    public string RecognizerLanguage => _engine?.RecognizerLanguage.LanguageTag ?? "(unavailable)";
    public uint MaxImageDimension => OcrEngine.MaxImageDimension;

    public WindowsNativeOcrEngine()
    {
        try
        {
            var lang = new Windows.Globalization.Language("en-US");
            _engine = OcrEngine.TryCreateFromLanguage(lang) ?? OcrEngine.TryCreateFromUserProfileLanguages();
        }
        catch (Exception ex)
        {
            InitializationException = ex;
            ConsoleLogger.Error("OCR_INITIALIZATION_FAILED");
            LogException(ex);
        }
    }

    /// <summary>
    /// Performs OCR recognition on a GDI+ Bitmap and maps coordinates with the given desktop offset.
    /// </summary>
    public async Task<CoreOcrResult> RecognizeBitmapAsync(Bitmap bitmap, double offsetX = 0, double offsetY = 0)
    {
        if (_engine == null)
        {
            throw new InvalidOperationException("OCR_INITIALIZATION_FAILED", InitializationException);
        }

        using var memoryStream = new MemoryStream();
        bitmap.Save(memoryStream, ImageFormat.Png);
        memoryStream.Position = 0;

        using var randomAccessStream = memoryStream.AsRandomAccessStream();
        var decoder = await BitmapDecoder.CreateAsync(randomAccessStream);
        using var softwareBitmap = await decoder.GetSoftwareBitmapAsync();

        return await RecognizeSoftwareBitmapAsync(softwareBitmap, offsetX, offsetY, bitmap.Width, bitmap.Height);
    }

    /// <summary>
    /// Performs OCR recognition on an image file from disk.
    /// </summary>
    public async Task<CoreOcrResult> RecognizeImageFileAsync(string imagePath, CancellationToken cancellationToken = default)
    {
        if (_engine == null || !File.Exists(imagePath))
        {
            if (_engine == null)
            {
                throw new InvalidOperationException("OCR_INITIALIZATION_FAILED", InitializationException);
            }

            throw new FileNotFoundException("OCR input image was not found.", imagePath);
        }

        using var bitmap = new Bitmap(imagePath);
        return await RecognizeBitmapAsync(bitmap, 0, 0);
    }

    /// <summary>
    /// Decodes and recognizes the saved PNG itself, matching the old PowerShell
    /// StorageFile -> BitmapDecoder -> SoftwareBitmap -> OcrEngine bridge.
    /// </summary>
    public async Task<OcrSmokeResult> RecognizeSavedPngForSmokeTestAsync(
        string imagePath,
        double offsetX,
        double offsetY)
    {
        if (_engine == null)
        {
            throw new InvalidOperationException("OCR_INITIALIZATION_FAILED", InitializationException);
        }

        if (!File.Exists(imagePath))
        {
            throw new FileNotFoundException("OCR smoke-test PNG was not found.", imagePath);
        }

        try
        {
            var storageFile = await Windows.Storage.StorageFile.GetFileFromPathAsync(Path.GetFullPath(imagePath));
            using var stream = await storageFile.OpenAsync(Windows.Storage.FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            using var softwareBitmap = await decoder.GetSoftwareBitmapAsync();

            Windows.Media.Ocr.OcrResult nativeResult;
            var stopwatch = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                nativeResult = await _engine.RecognizeAsync(softwareBitmap);
            }
            catch (Exception ex)
            {
                throw new OcrRecognizeException("OCR_RECOGNIZE_FAILED", ex);
            }
            finally
            {
                stopwatch.Stop();
            }

            var result = MapResult(nativeResult, offsetX, offsetY, softwareBitmap.PixelWidth, softwareBitmap.PixelHeight);
            return new OcrSmokeResult(
                result,
                softwareBitmap.PixelWidth,
                softwareBitmap.PixelHeight,
                softwareBitmap.BitmapPixelFormat.ToString(),
                softwareBitmap.BitmapAlphaMode.ToString(),
                stopwatch.Elapsed);
        }
        catch (OcrRecognizeException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new OcrBridgeException("OCR_BITMAP_BRIDGE_FAILED", ex);
        }
    }

    private async Task<CoreOcrResult> RecognizeSoftwareBitmapAsync(
        SoftwareBitmap softwareBitmap,
        double offsetX,
        double offsetY,
        double imageWidth,
        double imageHeight)
    {
        Windows.Media.Ocr.OcrResult ocrResult;
        try
        {
            ocrResult = await _engine!.RecognizeAsync(softwareBitmap);
        }
        catch (Exception ex)
        {
            throw new OcrRecognizeException("OCR_RECOGNIZE_FAILED", ex);
        }

        return MapResult(ocrResult, offsetX, offsetY, imageWidth, imageHeight);
    }

    private static CoreOcrResult MapResult(
        Windows.Media.Ocr.OcrResult ocrResult,
        double offsetX,
        double offsetY,
        double imageWidth,
        double imageHeight)
    {

        var lines = new List<CoreOcrLine>();
        var allWords = new List<CoreOcrWord>();

        foreach (var line in ocrResult.Lines)
        {
            var lineWords = new List<CoreOcrWord>();
            double lineLeft = double.MaxValue;
            double lineTop = double.MaxValue;
            double lineRight = double.MinValue;
            double lineBottom = double.MinValue;

            foreach (var word in line.Words)
            {
                var r = word.BoundingRect;
                double wordX = offsetX + r.X;
                double wordY = offsetY + r.Y;
                double wordW = r.Width;
                double wordH = r.Height;

                var ocrWord = new CoreOcrWord(word.Text, new BoundingRectangleInfo(wordX, wordY, wordW, wordH));
                lineWords.Add(ocrWord);
                allWords.Add(ocrWord);

                lineLeft = Math.Min(lineLeft, wordX);
                lineTop = Math.Min(lineTop, wordY);
                lineRight = Math.Max(lineRight, wordX + wordW);
                lineBottom = Math.Max(lineBottom, wordY + wordH);
            }

            var lineBounds = lineWords.Count > 0
                ? new BoundingRectangleInfo(lineLeft, lineTop, Math.Max(0, lineRight - lineLeft), Math.Max(0, lineBottom - lineTop))
                : BoundingRectangleInfo.Empty;

            lines.Add(new CoreOcrLine(line.Text, lineBounds, lineWords));
        }

        var totalBounds = new BoundingRectangleInfo(offsetX, offsetY, imageWidth, imageHeight);
        return new CoreOcrResult(lines, allWords, totalBounds);
    }

    private static void LogException(Exception exception)
    {
        for (Exception? current = exception; current != null; current = current.InnerException)
        {
            ConsoleLogger.Error($"Exception type : {current.GetType().FullName}");
            ConsoleLogger.Error($"Message        : {current.Message}");
            ConsoleLogger.Error($"HRESULT        : 0x{current.HResult:X8}");
            ConsoleLogger.Error($"Stack trace    : {current.StackTrace ?? "(none)"}");
            if (current.InnerException != null)
            {
                ConsoleLogger.Error("Inner exception:");
            }
        }
    }
}

public sealed record OcrSmokeResult(
    CoreOcrResult Result,
    int BitmapWidth,
    int BitmapHeight,
    string PixelFormat,
    string AlphaMode,
    TimeSpan RecognizeElapsed);

public sealed class OcrRecognizeException : Exception
{
    public OcrRecognizeException(string message, Exception innerException) : base(message, innerException) { }
}

public sealed class OcrBridgeException : Exception
{
    public OcrBridgeException(string message, Exception innerException) : base(message, innerException) { }
}
