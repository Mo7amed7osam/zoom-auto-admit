using System.Runtime.InteropServices;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Discovery;

public static class DesktopThread
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateThread(
        IntPtr lpThreadAttributes,
        uint dwStackSize,
        ThreadProc lpStartAddress,
        IntPtr lpParameter,
        uint dwCreationFlags,
        out uint lpThreadId
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    private const uint COINIT_APARTMENTTHREADED = 0x2;

    private delegate uint ThreadProc(IntPtr lpParameter);

    public static void RunOnInteractiveDesktop(Action action, uint timeoutMs = 60000)
    {
        Exception? caughtException = null;

        var hDesk = NativeMethods.OpenDesktop("Default", 0, false, NativeMethods.DESKTOP_ACCESS_ALL);
        if (hDesk == IntPtr.Zero)
        {
            hDesk = NativeMethods.OpenInputDesktop(0, false, NativeMethods.DESKTOP_ACCESS_ALL);
        }

        ThreadProc proc = (param) =>
        {
            if (hDesk != IntPtr.Zero)
            {
                var switched = NativeMethods.SetThreadDesktop(hDesk);
                ConsoleLogger.Debug($"Raw thread SetThreadDesktop result: {switched}");
            }

            CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
            try
            {
                action();
            }
            catch (Exception ex)
            {
                caughtException = ex;
            }
            finally
            {
                CoUninitialize();
            }
            return 0;
        };

        var hThread = CreateThread(IntPtr.Zero, 0, proc, IntPtr.Zero, 0, out _);
        if (hThread == IntPtr.Zero)
        {
            // Fallback to running directly
            action();
            return;
        }

        try
        {
            WaitForSingleObject(hThread, timeoutMs);
        }
        finally
        {
            CloseHandle(hThread);
        }

        if (caughtException != null)
        {
            throw new AggregateException("Error in desktop-attached thread", caughtException);
        }
    }
}
