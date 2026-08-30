using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ZoomAutoAdmit.UIAutomation.Input;

public interface IMouseInput
{
    void LeftClickOncePreservingCursor(int x, int y);
    void ScrollWheelPreservingCursor(int x, int y, int wheelDelta);
}

public sealed class SingleClickExecutor
{
    private readonly IMouseInput _mouseInput;
    private int _clickAttempted;

    public SingleClickExecutor(IMouseInput mouseInput)
    {
        _mouseInput = mouseInput;
    }

    public bool TryClick(int x, int y)
    {
        if (Interlocked.Exchange(ref _clickAttempted, 1) != 0)
        {
            return false;
        }

        _mouseInput.LeftClickOncePreservingCursor(x, y);
        return true;
    }
}

public sealed class WindowsMouseInput : IMouseInput
{
    private const uint InputMouse = 0;
    private const uint MouseEventLeftDown = 0x0002;
    private const uint MouseEventLeftUp = 0x0004;
    private const uint MouseEventWheel = 0x0800;

    public void LeftClickOncePreservingCursor(int x, int y)
    {
        if (!GetCursorPos(out var original))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetCursorPos failed.");
        }

        try
        {
            if (!SetCursorPos(x, y))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed.");
            }

            var inputs = new[]
            {
                CreateMouseInput(MouseEventLeftDown),
                CreateMouseInput(MouseEventLeftUp)
            };

            uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
            if (sent != inputs.Length)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"SendInput sent {sent} of {inputs.Length} events.");
            }
        }
        finally
        {
            if (!SetCursorPos(original.X, original.Y))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to restore the original cursor position.");
            }
        }
    }

    public void ScrollWheelPreservingCursor(int x, int y, int wheelDelta)
    {
        if (!GetCursorPos(out var original))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetCursorPos failed.");
        }

        try
        {
            if (!SetCursorPos(x, y))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed.");
            }

            var input = new INPUT
            {
                Type = InputMouse,
                Union = new INPUTUNION
                {
                    Mouse = new MOUSEINPUT
                    {
                        Flags = MouseEventWheel,
                        MouseData = unchecked((uint)wheelDelta)
                    }
                }
            };

            var inputs = new[] { input };
            uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
            if (sent != inputs.Length)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"SendInput sent {sent} of {inputs.Length} events.");
            }
        }
        finally
        {
            if (!SetCursorPos(original.X, original.Y))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to restore the original cursor position.");
            }
        }
    }

    private static INPUT CreateMouseInput(uint flags) => new()
    {
        Type = InputMouse,
        Union = new INPUTUNION
        {
            Mouse = new MOUSEINPUT { Flags = flags }
        }
    };

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint Type; public INPUTUNION Union; }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT Mouse; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }
}
