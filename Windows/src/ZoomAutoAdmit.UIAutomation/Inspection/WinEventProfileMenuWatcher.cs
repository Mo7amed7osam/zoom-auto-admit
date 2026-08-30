using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

/// <summary>
/// READ-ONLY WinEvent-based watcher that captures Zoom accessibility events
/// in real time. The user manually opens the Zoom profile/account popup
/// and this watcher captures newly created/shown elements for UIA inspection.
/// Does NOT click, focus, activate, or modify Zoom in any way.
/// </summary>
public class WinEventProfileMenuWatcher
{
    // WinEvent constants
    private const uint EVENT_OBJECT_CREATE = 0x8000;
    private const uint EVENT_OBJECT_SHOW = 0x8002;
    private const uint EVENT_OBJECT_REORDER = 0x8004;
    private const uint EVENT_SYSTEM_MENUPOPUPSTART = 0x0006;
    private const uint EVENT_SYSTEM_MENUPOPUPEND = 0x0007;
    private const uint EVENT_OBJECT_FOCUS = 0x8005;
    private const uint EVENT_OBJECT_NAMECHANGE = 0x800C;
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;

    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

    // P/Invoke for SetWinEventHook
    private delegate void WinEventDelegate(
        IntPtr hWinEventHook, uint eventType,
        IntPtr hwnd, int idObject, int idChild,
        uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax,
        IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess, uint idThread,
        uint dwFlags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    // GetMessage returns int: 0 = WM_QUIT, -1 = error, >0 = message available
    // We use int return to properly handle -1 error case.
    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    private const uint WM_QUIT = 0x0012;

    // Result data
    public record WatchResult(
        List<CapturedEvent> Events,
        List<InspectElementInfo> CapturedTrees,
        List<string> ExtractedTexts,
        List<string> Diagnostics
    );

    public record CapturedEvent(
        DateTime Timestamp,
        string EventName,
        IntPtr Hwnd,
        int ObjectId,
        int ChildId,
        uint ProcessId,
        string WindowClassName,
        string WindowTitle,
        bool IsVisible,
        BoundingRectangleInfo? Bounds
    );

    private readonly List<CapturedEvent> _events = new();
    private readonly List<InspectElementInfo> _capturedTrees = new();
    private readonly List<string> _diagnostics = new();
    private readonly HashSet<string> _extractedTexts = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<IntPtr> _capturedHwnds = new();
    private readonly object _lock = new();
    private HashSet<int> _zoomPids = new();
    private int _maxDepth = 25;
    private int _maxElements = 1500;
    private uint _messageThreadId;

    // Keep delegate alive to prevent GC collection while hook is active
    private WinEventDelegate? _hookDelegate;

    public WatchResult Watch(int timeoutSeconds, int? targetPid = null, int maxDepth = 25, int maxElements = 1500)
    {
        _maxDepth = maxDepth;
        _maxElements = maxElements;

        // 1. Discover Zoom processes FIRST
        ConsoleLogger.Info("Discovering Zoom processes...");
        var candidates = new ZoomProcessDiscovery().FindCandidates();
        _zoomPids = candidates.Select(c => c.ProcessId).ToHashSet();

        if (targetPid.HasValue)
        {
            _zoomPids = new HashSet<int> { targetPid.Value };
        }

        if (_zoomPids.Count == 0)
        {
            ConsoleLogger.Warn("No Zoom Workplace processes found.");
            _diagnostics.Add("No Zoom Workplace processes found.");
            return BuildResult();
        }

        ConsoleLogger.Info($"Watching Zoom PIDs: [{string.Join(", ", _zoomPids)}]");
        _diagnostics.Add($"Watching Zoom PIDs: [{string.Join(", ", _zoomPids)}]");

        // 2. Run hooks + message pump on a dedicated STA thread
        //    The ENTIRE lifecycle (install → listen → unhook) happens inside this thread.
        //    The user prompt is printed AFTER hooks are installed.
        Exception? threadException = null;
        using var hooksReady = new ManualResetEventSlim(false);
        var localHooksReady = hooksReady;

        var watchThread = new Thread(() =>
        {
            try
            {
                RunMessagePumpWithHooks(timeoutSeconds, localHooksReady);
            }
            catch (Exception ex)
            {
                threadException = ex;
                localHooksReady.Set(); // unblock main thread on failure
            }
        });
        watchThread.SetApartmentState(ApartmentState.STA);
        watchThread.IsBackground = true;
        watchThread.Start();

        // Wait for hooks to be installed before returning control
        // (the watch thread signals hooksReady after installing hooks)
        hooksReady.Wait(TimeSpan.FromSeconds(15));

        // Now wait for the watch to complete
        watchThread.Join(TimeSpan.FromSeconds(timeoutSeconds + 15));

        if (threadException != null)
        {
            ConsoleLogger.Error($"WinEvent thread error: {threadException.Message}");
            _diagnostics.Add($"WinEvent thread error: {threadException.Message}");
        }

        return BuildResult();
    }

    private void RunMessagePumpWithHooks(int timeoutSeconds, ManualResetEventSlim hooksReady)
    {
        _messageThreadId = GetCurrentThreadId();

        // Store delegate as instance field — prevents GC while hooks are active
        _hookDelegate = OnWinEvent;

        var hooks = new List<IntPtr>();

        try
        {
            // ---- STEP 1: Install all WinEvent hooks FIRST ----
            ConsoleLogger.Info("Installing WinEvent hooks...");

            foreach (var pid in _zoomPids)
            {
                // Object events: CREATE, SHOW, REORDER
                var h1 = SetWinEventHook(
                    EVENT_OBJECT_CREATE, EVENT_OBJECT_REORDER,
                    IntPtr.Zero, _hookDelegate,
                    (uint)pid, 0, WINEVENT_OUTOFCONTEXT);
                if (h1 != IntPtr.Zero)
                {
                    hooks.Add(h1);
                    ConsoleLogger.Debug($"  Hook: OBJECT_CREATE..REORDER for PID {pid} → 0x{h1.ToInt64():X}");
                }

                // Focus events
                var h2 = SetWinEventHook(
                    EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS,
                    IntPtr.Zero, _hookDelegate,
                    (uint)pid, 0, WINEVENT_OUTOFCONTEXT);
                if (h2 != IntPtr.Zero)
                {
                    hooks.Add(h2);
                    ConsoleLogger.Debug($"  Hook: OBJECT_FOCUS for PID {pid} → 0x{h2.ToInt64():X}");
                }

                // Name change events
                var h3 = SetWinEventHook(
                    EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE,
                    IntPtr.Zero, _hookDelegate,
                    (uint)pid, 0, WINEVENT_OUTOFCONTEXT);
                if (h3 != IntPtr.Zero)
                {
                    hooks.Add(h3);
                    ConsoleLogger.Debug($"  Hook: OBJECT_NAMECHANGE for PID {pid} → 0x{h3.ToInt64():X}");
                }
            }

            // Global: system menu popup events (popups may spawn under different PIDs)
            var hMenu = SetWinEventHook(
                EVENT_SYSTEM_MENUPOPUPSTART, EVENT_SYSTEM_MENUPOPUPEND,
                IntPtr.Zero, _hookDelegate,
                0, 0, WINEVENT_OUTOFCONTEXT);
            if (hMenu != IntPtr.Zero)
            {
                hooks.Add(hMenu);
                ConsoleLogger.Debug($"  Hook: MENUPOPUPSTART..END (global) → 0x{hMenu.ToInt64():X}");
            }

            // Global: foreground changes (catch popup window coming to front)
            var hFg = SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero, _hookDelegate,
                0, 0, WINEVENT_OUTOFCONTEXT);
            if (hFg != IntPtr.Zero)
            {
                hooks.Add(hFg);
                ConsoleLogger.Debug($"  Hook: SYSTEM_FOREGROUND (global) → 0x{hFg.ToInt64():X}");
            }

            ConsoleLogger.Info($"Installed {hooks.Count} WinEvent hook(s).");
            _diagnostics.Add($"Installed {hooks.Count} WinEvent hook(s).");

            if (hooks.Count == 0)
            {
                ConsoleLogger.Error("FAILED to install any WinEvent hooks. Cannot listen for events.");
                _diagnostics.Add("FAILED to install any WinEvent hooks.");
                hooksReady.Set();
                return;
            }

            // ---- STEP 2: Signal hooks are ready, THEN print user prompt ----
            hooksReady.Set();

            ConsoleLogger.Info("================================================================================");
            ConsoleLogger.Info($"  Watching Zoom UI events for {timeoutSeconds} seconds.                         ");
            ConsoleLogger.Info("  Click the Zoom profile/avatar button NOW.                                    ");
            ConsoleLogger.Info("  Events will be captured in real time below.                                   ");
            ConsoleLogger.Info("================================================================================");

            // ---- STEP 3: Start timeout timer ----
            var savedThreadId = _messageThreadId;
            var timerThread = new Thread(() =>
            {
                Thread.Sleep(timeoutSeconds * 1000);
                ConsoleLogger.Info("Watch timeout reached.");
                _diagnostics.Add($"Watch timeout reached after {timeoutSeconds}s.");
                PostThreadMessage(savedThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            });
            timerThread.IsBackground = true;
            timerThread.Start();

            // ---- STEP 4: Run message pump — WinEvent callbacks are delivered here ----
            ConsoleLogger.Debug($"Message pump started on thread {_messageThreadId}.");
            int getMessageResult;
            while ((getMessageResult = GetMessageW(out var msg, IntPtr.Zero, 0, 0)) != 0)
            {
                if (getMessageResult == -1)
                {
                    // GetMessage error
                    var error = Marshal.GetLastWin32Error();
                    ConsoleLogger.Warn($"GetMessage returned -1, Win32 error: {error}. Retrying...");
                    continue;
                }

                TranslateMessage(ref msg);
                DispatchMessageW(ref msg);
            }

            ConsoleLogger.Debug("Message pump exited (WM_QUIT received).");
        }
        finally
        {
            // ---- STEP 5: Unhook AFTER the message pump exits ----
            foreach (var h in hooks)
            {
                UnhookWinEvent(h);
            }
            ConsoleLogger.Info($"Unhooked {hooks.Count} WinEvent hook(s).");
            _diagnostics.Add($"Unhooked {hooks.Count} WinEvent hook(s).");
        }
    }

    private void OnWinEvent(
        IntPtr hWinEventHook, uint eventType,
        IntPtr hwnd, int idObject, int idChild,
        uint dwEventThread, uint dwmsEventTime)
    {
        if (hwnd == IntPtr.Zero)
            return;

        // Get basic window info
        NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
        var className = NativeMethods.GetClassNameSafe(hwnd);
        var title = NativeMethods.GetWindowTitleSafe(hwnd);
        var isVisible = NativeMethods.IsWindowVisible(hwnd);
        BoundingRectangleInfo? bounds = null;

        if (NativeMethods.GetWindowRect(hwnd, out var rect))
        {
            bounds = rect.ToBoundingRectangle();
        }

        var eventName = EventName(eventType);

        // Filter: only log events from Zoom PIDs or known menu/popup events
        bool isZoomPid = _zoomPids.Contains((int)pid);
        bool isSystemMenuEvent = eventType is EVENT_SYSTEM_MENUPOPUPSTART or EVENT_SYSTEM_MENUPOPUPEND;
        bool isSystemForeground = eventType == EVENT_SYSTEM_FOREGROUND;

        // For foreground/menu events from non-Zoom PIDs, check if it's plausibly Zoom-related
        if (!isZoomPid && !isSystemMenuEvent)
        {
            if (isSystemForeground)
            {
                bool isZoomLike = className.IndexOf("zoom", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                  className.IndexOf("ZPPTMainFrmWndClassEx", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                  className.IndexOf("ZPContentViewWndClass", StringComparison.OrdinalIgnoreCase) >= 0;
                if (!isZoomLike) return;
            }
            else
            {
                return;
            }
        }

        var evt = new CapturedEvent(
            DateTime.Now, eventName, hwnd,
            idObject, idChild, pid,
            className, title, isVisible, bounds);

        lock (_lock)
        {
            _events.Add(evt);
        }

        // Log to console in real time
        var boundsStr = bounds != null ? $"{bounds.X},{bounds.Y} {bounds.Width}x{bounds.Height}" : "n/a";
        ConsoleLogger.Info($"[EVENT] {eventName,-28} HWND=0x{hwnd.ToInt64():X8} PID={pid,-6} Visible={isVisible,-5} Class='{className}' Title='{title}' Bounds=({boundsStr}) ObjId={idObject} ChildId={idChild}");

        // For significant popup/create/show events on visible windows, attempt UIA capture
        bool shouldCapture = (eventType is EVENT_OBJECT_CREATE or EVENT_OBJECT_SHOW or EVENT_SYSTEM_MENUPOPUPSTART)
                             && isVisible
                             && bounds != null && bounds.Width > 10 && bounds.Height > 10;

        if (shouldCapture)
        {
            lock (_lock)
            {
                if (!_capturedHwnds.Contains(hwnd))
                {
                    _capturedHwnds.Add(hwnd);
                    ConsoleLogger.Info($">>> Queuing UIA capture for HWND=0x{hwnd.ToInt64():X8}...");
                    CaptureUiaTree(hwnd, eventName, pid);
                }
            }
        }
    }

    private void CaptureUiaTree(IntPtr hwnd, string eventName, uint pid)
    {
        try
        {
            using var automation = new UIA3Automation();
            var element = automation.FromHandle(hwnd);
            if (element == null)
            {
                ConsoleLogger.Warn($"UIA FromHandle(0x{hwnd.ToInt64():X}) returned null.");
                _diagnostics.Add($"UIA FromHandle(0x{hwnd.ToInt64():X}) returned null for event '{eventName}'.");
                return;
            }

            int totalVisited = 0;
            var tree = TraverseSubtree(element, 0, _maxDepth, _maxElements, ref totalVisited);
            if (tree != null)
            {
                lock (_lock)
                {
                    _capturedTrees.Add(tree);
                }
                ConsoleLogger.Info($">>> UIA CAPTURE COMPLETE: HWND=0x{hwnd.ToInt64():X} ({totalVisited} elements) triggered by {eventName}");
                _diagnostics.Add($"Captured UIA tree for HWND=0x{hwnd.ToInt64():X} (PID={pid}, event={eventName}): {totalVisited} element(s).");
            }
        }
        catch (Exception ex)
        {
            ConsoleLogger.Warn($"UIA capture failed for HWND=0x{hwnd.ToInt64():X}: {ex.Message}");
            _diagnostics.Add($"UIA capture failed for HWND=0x{hwnd.ToInt64():X}: {ex.Message}");
        }
    }

    private InspectElementInfo? TraverseSubtree(
        AutomationElement element, int depth, int maxDepth, int maxElements, ref int totalVisited)
    {
        if (depth > maxDepth || totalVisited >= maxElements)
            return null;

        totalVisited++;
        var node = FlaUiElementExtractor.ExtractElementInfo(element, depth);

        if (!string.IsNullOrWhiteSpace(node.Name))
            _extractedTexts.Add(node.Name.Trim());
        if (!string.IsNullOrWhiteSpace(node.LegacyName))
            _extractedTexts.Add(node.LegacyName.Trim());
        if (!string.IsNullOrWhiteSpace(node.Value))
            _extractedTexts.Add(node.Value.Trim());

        try
        {
            var children = element.FindAllChildren();
            foreach (var child in children)
            {
                var childNode = TraverseSubtree(child, depth + 1, maxDepth, maxElements, ref totalVisited);
                if (childNode != null)
                    node.Children.Add(childNode);
            }
        }
        catch (Exception ex)
        {
            node.DiagnosticError = ex.Message;
        }

        return node;
    }

    private WatchResult BuildResult()
    {
        return new WatchResult(
            _events.ToList(),
            _capturedTrees.ToList(),
            _extractedTexts.Where(t => !string.IsNullOrWhiteSpace(t)).ToList(),
            _diagnostics.ToList()
        );
    }

    private static string EventName(uint eventType) => eventType switch
    {
        EVENT_OBJECT_CREATE => "EVENT_OBJECT_CREATE",
        EVENT_OBJECT_SHOW => "EVENT_OBJECT_SHOW",
        EVENT_OBJECT_REORDER => "EVENT_OBJECT_REORDER",
        EVENT_SYSTEM_MENUPOPUPSTART => "EVENT_SYSTEM_MENUPOPUPSTART",
        EVENT_SYSTEM_MENUPOPUPEND => "EVENT_SYSTEM_MENUPOPUPEND",
        EVENT_OBJECT_FOCUS => "EVENT_OBJECT_FOCUS",
        EVENT_OBJECT_NAMECHANGE => "EVENT_OBJECT_NAMECHANGE",
        EVENT_SYSTEM_FOREGROUND => "EVENT_SYSTEM_FOREGROUND",
        _ => $"EVENT_0x{eventType:X4}"
    };
}
