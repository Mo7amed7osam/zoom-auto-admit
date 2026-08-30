using ZoomAutoAdmit.Core.Matching;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class FrameAcquisitionFailureClassifierTests
{
    [Fact]
    public void ExpectedCancellationIsWatchTimeout()
    {
        var result = FrameAcquisitionFailureClassifier.Classify(
            new OperationCanceledException(),
            cancellationRequested: true);

        Assert.Equal(FrameAcquisitionFailureKind.WatchTimeout, result);
    }

    [Fact]
    public void GenuineOcrExceptionRemainsCaptureOrOcrFailed()
    {
        var result = FrameAcquisitionFailureClassifier.Classify(
            new InvalidOperationException("OCR_RECOGNIZE_FAILED"),
            cancellationRequested: false);

        Assert.Equal(FrameAcquisitionFailureKind.CaptureOrOcrFailed, result);
    }

    [Fact]
    public void UnrequestedOperationCancellationIsNotMisclassifiedAsWatchTimeout()
    {
        var result = FrameAcquisitionFailureClassifier.Classify(
            new OperationCanceledException(),
            cancellationRequested: false);

        Assert.Equal(FrameAcquisitionFailureKind.CaptureOrOcrFailed, result);
    }
}
