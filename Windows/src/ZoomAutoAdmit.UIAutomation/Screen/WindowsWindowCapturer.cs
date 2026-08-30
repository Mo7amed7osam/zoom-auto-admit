using System.Drawing;
using System.Drawing.Imaging;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Screen;

public sealed record WindowCaptureResult(
    IntPtr WindowHandle,
    Bitmap? Bitmap,
    BoundingRectangleInfo WindowBounds,
    BoundingRectangleInfo ClientBounds,
    bool IsSuccessful,
    string FailureReason) : IDisposable
{
    public void Dispose()
    {
        Bitmap?.Dispose();
    }
}

public static class WindowsWindowCapturer
{
    public static WindowCaptureResult CaptureWindow(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero || !NativeMethods.IsWindow(hWnd))
        {
            return new WindowCaptureResult(hWnd, null, BoundingRectangleInfo.Empty, BoundingRectangleInfo.Empty, false, "Invalid or closed window handle.");
        }

        if (!NativeMethods.GetWindowRect(hWnd, out var winRect))
        {
            return new WindowCaptureResult(hWnd, null, BoundingRectangleInfo.Empty, BoundingRectangleInfo.Empty, false, "GetWindowRect failed.");
        }

        int width = winRect.Right - winRect.Left;
        int height = winRect.Bottom - winRect.Top;

        if (width <= 0 || height <= 0)
        {
            return new WindowCaptureResult(hWnd, null, BoundingRectangleInfo.Empty, BoundingRectangleInfo.Empty, false, "Window has zero or negative dimensions.");
        }

        var windowBounds = new BoundingRectangleInfo(winRect.Left, winRect.Top, width, height);

        var clientBounds = windowBounds;
        if (NativeMethods.GetClientRect(hWnd, out var clRect))
        {
            var pt = new NativeMethods.POINT { X = 0, Y = 0 };
            NativeMethods.ClientToScreen(hWnd, ref pt);
            clientBounds = new BoundingRectangleInfo(pt.X, pt.Y, clRect.Right - clRect.Left, clRect.Bottom - clRect.Top);
        }

        try
        {
            var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                IntPtr hdc = g.GetHdc();
                try
                {
                    bool ok = NativeMethods.PrintWindow(hWnd, hdc, NativeMethods.PW_RENDERFULLCONTENT);
                    if (!ok)
                    {
                        ok = NativeMethods.PrintWindow(hWnd, hdc, 0);
                    }

                    if (!ok)
                    {
                        bmp.Dispose();
                        return new WindowCaptureResult(hWnd, null, windowBounds, clientBounds, false, "PrintWindow call returned false.");
                    }
                }
                finally
                {
                    g.ReleaseHdc(hdc);
                }
            }

            return new WindowCaptureResult(hWnd, bmp, windowBounds, clientBounds, true, string.Empty);
        }
        catch (Exception ex)
        {
            return new WindowCaptureResult(hWnd, null, windowBounds, clientBounds, false, $"Window capture exception: {ex.Message}");
        }
    }
}
