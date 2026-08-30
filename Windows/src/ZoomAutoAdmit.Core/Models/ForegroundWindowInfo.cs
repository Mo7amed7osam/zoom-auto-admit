namespace ZoomAutoAdmit.Core.Models;

public record ForegroundWindowInfo(
    IntPtr Handle,
    int ProcessId,
    string ProcessName,
    string WindowTitle
);
