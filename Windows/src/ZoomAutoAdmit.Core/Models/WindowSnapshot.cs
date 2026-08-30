namespace ZoomAutoAdmit.Core.Models;

public record WindowSnapshot(
    IntPtr Handle,
    int ProcessId,
    string ProcessName,
    string ClassName,
    string Title,
    bool IsVisible,
    BoundingRectangleInfo Bounds
);

public record WindowDiffResult(
    List<WindowSnapshot> NewWindows,
    List<WindowSnapshot> BecameVisibleWindows,
    List<WindowSnapshot> ResizedToNonZeroWindows,
    List<WindowSnapshot> PrimaryCandidates
);
