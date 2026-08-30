using System.Runtime.InteropServices;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Window;

public enum ZoomWindowRole
{
    Unknown,
    MeetingWindow,
    ParticipantsWindow,
    MeetingChat,
    NotificationToast,
    Other
}

public sealed class ZoomWindowManager
{
    private static readonly string[] ZoomClasses =
    [
        "ZPContentViewWndClass",
        "ConfMultiTabContentWndClass",
        "zMeetingNotificationWndClass",
        "ZPFloatVideoWndClass",
        "ZVideoStatusWndClass"
    ];

    public static ZoomWindowRole ClassifyZoomWindow(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero || !NativeMethods.IsWindow(hWnd)) return ZoomWindowRole.Unknown;

        string title = NativeMethods.GetWindowTitleSafe(hWnd);
        string className = NativeMethods.GetClassNameSafe(hWnd);
        string process = NativeMethods.GetProcessNameSafe(hWnd);

        if (!process.Contains("zoom", StringComparison.OrdinalIgnoreCase) &&
            !process.Equals("cptHost", StringComparison.OrdinalIgnoreCase))
        {
            return ZoomWindowRole.Unknown;
        }

        if (title.Contains("Chat", StringComparison.OrdinalIgnoreCase) ||
            title.Contains("Meeting Chat", StringComparison.OrdinalIgnoreCase))
        {
            return ZoomWindowRole.MeetingChat;
        }

        if (title.Contains("Participants", StringComparison.OrdinalIgnoreCase))
        {
            return ZoomWindowRole.ParticipantsWindow;
        }

        if (className.Equals("zMeetingNotificationWndClass", StringComparison.OrdinalIgnoreCase))
        {
            return ZoomWindowRole.NotificationToast;
        }

        if (className.Equals("ZPContentViewWndClass", StringComparison.OrdinalIgnoreCase) ||
            className.Equals("ConfMultiTabContentWndClass", StringComparison.OrdinalIgnoreCase) ||
            title.Contains("Zoom Meeting", StringComparison.OrdinalIgnoreCase) ||
            title.Contains("Zoom Webinar", StringComparison.OrdinalIgnoreCase))
        {
            return ZoomWindowRole.MeetingWindow;
        }

        return ZoomWindowRole.Other;
    }

    public static IntPtr FindParticipantsWindow()
    {
        IntPtr found = IntPtr.Zero;
        NativeMethods.EnumWindows((hWnd, _) =>
        {
            if (ClassifyZoomWindow(hWnd) == ZoomWindowRole.ParticipantsWindow)
            {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindMainZoomMeetingWindow()
    {
        IntPtr found = IntPtr.Zero;
        NativeMethods.EnumWindows((hWnd, _) =>
        {
            if (ClassifyZoomWindow(hWnd) == ZoomWindowRole.MeetingWindow)
            {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindActiveZoomWindow()
    {
        // 1. If Participants window is open, prefer it for waiting room operations
        var partWnd = FindParticipantsWindow();
        if (partWnd != IntPtr.Zero)
        {
            Console.WriteLine($"PARTICIPANTS_WINDOW_SELECTED: HWND=0x{partWnd.ToInt64():X}");
            return partWnd;
        }

        // 2. Otherwise use main meeting window
        var meetingWnd = FindMainZoomMeetingWindow();
        if (meetingWnd != IntPtr.Zero)
        {
            Console.WriteLine($"ZOOM_MEETING_WINDOW_SELECTED: HWND=0x{meetingWnd.ToInt64():X}");
            return meetingWnd;
        }

        // 3. Fallback to any valid non-chat Zoom window
        IntPtr fallback = IntPtr.Zero;
        NativeMethods.EnumWindows((hWnd, _) =>
        {
            var role = ClassifyZoomWindow(hWnd);
            if (role != ZoomWindowRole.Unknown && role != ZoomWindowRole.MeetingChat)
            {
                fallback = hWnd;
                return false;
            }
            if (role == ZoomWindowRole.MeetingChat)
            {
                Console.WriteLine($"MEETING_CHAT_IGNORED: HWND=0x{hWnd.ToInt64():X}");
            }
            return true;
        }, IntPtr.Zero);

        return fallback;
    }

    public static bool IsZoomTopmostAt(double x, double y)
    {
        var evidence = NativeMethods.GetWindowAtPointEvidenceSafe(x, y);
        string proc = evidence.TargetProcess.Trim();
        if (proc.Contains("zoom", StringComparison.OrdinalIgnoreCase) ||
            proc.Equals("cptHost", StringComparison.OrdinalIgnoreCase) ||
            evidence.HasZoomParentOwnerChain)
        {
            return true;
        }

        return false;
    }

    public static bool IsWindowMinimized(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        return NativeMethods.IsIconic(hWnd);
    }
}
