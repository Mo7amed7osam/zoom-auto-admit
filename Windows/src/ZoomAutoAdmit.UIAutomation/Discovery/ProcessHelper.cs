using System.Diagnostics;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Discovery;

public static class ProcessHelper
{
    public static string? TryGetMainModuleFileName(Process process)
    {
        try
        {
            return process.MainModule?.FileName;
        }
        catch
        {
            return null;
        }
    }

    public static IReadOnlyList<ZoomWindowInfo> GetWindowsForProcess(int processId)
    {
        var windows = new List<ZoomWindowInfo>();

        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            NativeMethods.EnumWindows((hWnd, _) =>
            {
                NativeMethods.GetWindowThreadProcessId(hWnd, out var windowProcessId);
                if (windowProcessId == (uint)processId)
                {
                    var title = NativeMethods.GetWindowTitleSafe(hWnd);
                    var className = NativeMethods.GetClassNameSafe(hWnd);
                    var isVisible = NativeMethods.IsWindowVisible(hWnd);
                    NativeMethods.GetWindowRect(hWnd, out var rect);

                    windows.Add(new ZoomWindowInfo(
                        hWnd,
                        title,
                        className,
                        isVisible,
                        rect.ToBoundingRectangle()
                    ));
                }
                return true;
            }, IntPtr.Zero);
        });

        return windows;
    }
}
