namespace ZoomAutoAdmit.Core.Models;

public sealed record AutoAdmitScan(
    WaitingRoomToastDetectionResult Detection,
    MultiPersonWaitingDetectionResult MultiPersonDetection,
    OcrResult Ocr,
    BoundingRectangleInfo PrimaryBounds,
    DateTimeOffset CaptureCompletedAt);
