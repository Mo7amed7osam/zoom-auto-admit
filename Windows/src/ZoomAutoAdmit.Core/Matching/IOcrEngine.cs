using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

/// <summary>
/// Abstraction for OCR engine operations.
/// </summary>
public interface IOcrEngine
{
    /// <summary>
    /// Checks whether the OCR engine is available and initialized on the system.
    /// </summary>
    bool IsAvailable { get; }

    /// <summary>
    /// Recognizes text in the provided image file or stream.
    /// </summary>
    Task<OcrResult> RecognizeImageFileAsync(string imagePath, CancellationToken cancellationToken = default);
}
