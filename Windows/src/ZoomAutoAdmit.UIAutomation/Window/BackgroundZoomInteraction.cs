using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Window;

public enum BackgroundInteractionResult
{
    Success,
    InvalidTargetWindow,
    TargetIsMeetingChat,
    WindowNotRendered,
    Unsupported
}

public static class BackgroundZoomInteraction
{
    private static IntPtr MakeLParam(int x, int y) => (IntPtr)((y << 16) | (x & 0xFFFF));

    public static (int ClientX, int ClientY) ToClientCoordinates(IntPtr hWnd, double absoluteX, double absoluteY)
    {
        var pt = new NativeMethods.POINT
        {
            X = checked((int)Math.Round(absoluteX)),
            Y = checked((int)Math.Round(absoluteY))
        };
        NativeMethods.ScreenToClient(hWnd, ref pt);
        return (pt.X, pt.Y);
    }

    public static (double AbsoluteX, double AbsoluteY) ToAbsoluteCoordinates(IntPtr hWnd, int clientX, int clientY)
    {
        var pt = new NativeMethods.POINT { X = clientX, Y = clientY };
        NativeMethods.ClientToScreen(hWnd, ref pt);
        return (pt.X, pt.Y);
    }

    public static BackgroundInteractionResult ValidateTarget(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero || !NativeMethods.IsWindow(hWnd))
            return BackgroundInteractionResult.InvalidTargetWindow;

        var role = ZoomWindowManager.ClassifyZoomWindow(hWnd);
        if (role == ZoomWindowRole.MeetingChat)
        {
            Console.WriteLine($"MEETING_CHAT_IGNORED: HWND=0x{hWnd.ToInt64():X}");
            return BackgroundInteractionResult.TargetIsMeetingChat;
        }

        if (role == ZoomWindowRole.Unknown)
            return BackgroundInteractionResult.InvalidTargetWindow;

        return BackgroundInteractionResult.Success;
    }

    public static bool SendMouseMove(IntPtr hWnd, int clientX, int clientY)
    {
        if (ValidateTarget(hWnd) != BackgroundInteractionResult.Success) return false;

        var lParam = MakeLParam(clientX, clientY);
        return NativeMethods.PostMessage(hWnd, NativeMethods.WM_MOUSEMOVE, IntPtr.Zero, lParam);
    }

    public static bool SendMouseClick(IntPtr hWnd, int clientX, int clientY)
    {
        if (ValidateTarget(hWnd) != BackgroundInteractionResult.Success) return false;

        var lParam = MakeLParam(clientX, clientY);
        bool down = NativeMethods.PostMessage(hWnd, NativeMethods.WM_LBUTTONDOWN, (IntPtr)NativeMethods.MK_LBUTTON, lParam);
        Thread.Sleep(50);
        bool up = NativeMethods.PostMessage(hWnd, NativeMethods.WM_LBUTTONUP, IntPtr.Zero, lParam);
        return down && up;
    }

    public static bool SendMouseWheel(IntPtr hWnd, int clientX, int clientY, int delta)
    {
        if (ValidateTarget(hWnd) != BackgroundInteractionResult.Success) return false;

        var pt = new NativeMethods.POINT { X = clientX, Y = clientY };
        NativeMethods.ClientToScreen(hWnd, ref pt);
        var lParam = MakeLParam(pt.X, pt.Y);
        var wParam = (IntPtr)(delta << 16);

        return NativeMethods.PostMessage(hWnd, NativeMethods.WM_MOUSEWHEEL, wParam, lParam);
    }
}
