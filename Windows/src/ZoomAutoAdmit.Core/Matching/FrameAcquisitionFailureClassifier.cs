namespace ZoomAutoAdmit.Core.Matching;

public enum FrameAcquisitionFailureKind
{
    WatchTimeout,
    CaptureOrOcrFailed
}

public static class FrameAcquisitionFailureClassifier
{
    public static FrameAcquisitionFailureKind Classify(Exception exception, bool cancellationRequested) =>
        exception is OperationCanceledException && cancellationRequested
            ? FrameAcquisitionFailureKind.WatchTimeout
            : FrameAcquisitionFailureKind.CaptureOrOcrFailed;
}
