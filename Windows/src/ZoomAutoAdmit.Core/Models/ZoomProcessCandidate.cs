namespace ZoomAutoAdmit.Core.Models;

public record ZoomWindowInfo(
    IntPtr Handle,
    string Title,
    string ClassName,
    bool IsVisible,
    BoundingRectangleInfo Bounds
);

public record ZoomProcessCandidate(
    int ProcessId,
    string ProcessName,
    string? ExecutablePath,
    IntPtr MainWindowHandle,
    string MainWindowTitle,
    IReadOnlyList<ZoomWindowInfo> Windows,
    bool IsAccessible
);
