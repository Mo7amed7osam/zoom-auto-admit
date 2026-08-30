using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

/// <summary>
/// Diagnostic watcher for active Zoom meeting windows, Participants panel,
/// and Waiting Room controls. Tests UI readability and pattern availability
/// in both Foreground (State A) and Background (State B) states.
/// STRICTLY READ-ONLY: Never invokes, clicks, or modifies any controls.
/// </summary>
public class MeetingWatcher
{
    // WinEvent constants
    private const uint EVENT_OBJECT_CREATE = 0x8000;
    private const uint EVENT_OBJECT_DESTROY = 0x8001;
    private const uint EVENT_OBJECT_SHOW = 0x8002;
    private const uint EVENT_OBJECT_REORDER = 0x8004;
    private const uint EVENT_OBJECT_FOCUS = 0x8005;
    private const uint EVENT_OBJECT_STATECHANGE = 0x800A;
    private const uint EVENT_OBJECT_NAMECHANGE = 0x800C;
    private const uint EVENT_OBJECT_VALUECHANGE = 0x800E;
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint EVENT_SYSTEM_MENUPOPUPSTART = 0x0006;
    private const uint EVENT_SYSTEM_MENUPOPUPEND = 0x0007;

    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

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

    public record MeetingSnapshot(
        DateTime Timestamp,
        ForegroundWindowInfo ForegroundWindow,
        bool IsZoomForeground,
        List<WindowSnapshot> ZoomWindows,
        List<InspectElementInfo> MeetingTrees,
        List<WaitingParticipantInfo> WaitingParticipants,
        List<InspectElementInfo> AdmitButtons,
        List<InspectElementInfo> AdmitAllButtons
    );

    public record WaitingParticipantInfo(
        string DisplayName,
        string FullText,
        InspectElementInfo RowElement,
        InspectElementInfo? AssociatedAdmitButton
    );

    public record MeetingWatchResult(
        List<ZoomProcessCandidate> DetectedProcesses,
        List<WindowSnapshot> AllZoomWindows,
        List<MeetingSnapshot> ForegroundSnapshots,
        List<MeetingSnapshot> BackgroundSnapshots,
        List<WinEventProfileMenuWatcher.CapturedEvent> Events,
        List<string> Diagnostics
    );

    private readonly List<WinEventProfileMenuWatcher.CapturedEvent> _events = new();
    private readonly List<MeetingSnapshot> _foregroundSnapshots = new();
    private readonly List<MeetingSnapshot> _backgroundSnapshots = new();
    private readonly List<string> _diagnostics = new();
    private readonly object _lock = new();
    private HashSet<int> _zoomPids = new();
    private List<ZoomProcessCandidate> _candidates = new();
    private List<WindowSnapshot> _allZoomWindows = new();
    private int _maxDepth = 25;
    private int _maxElements = 2000;
    private uint _messageThreadId;
    private WinEventDelegate? _hookDelegate;

    public MeetingWatchResult Watch(int timeoutSeconds, int? targetPid = null, int maxDepth = 25, int maxElements = 2000)
    {
        _maxDepth = maxDepth;
        _maxElements = maxElements;

        // 1. Discover all Zoom processes and candidate windows
        ConsoleLogger.Info("Discovering all Zoom processes and meeting windows...");
        _candidates = new ZoomProcessDiscovery().FindCandidates().ToList();
        _zoomPids = _candidates.Select(c => c.ProcessId).ToHashSet();

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

        ConsoleLogger.Info($"Target Zoom PIDs: [{string.Join(", ", _zoomPids)}]");
        _diagnostics.Add($"Target Zoom PIDs: [{string.Join(", ", _zoomPids)}]");

        // Enumerate initial top-level windows for all Zoom processes
        _allZoomWindows = CaptureZoomWindows();
        ConsoleLogger.Info($"Discovered {_allZoomWindows.Count} Zoom window handle(s):");
        foreach (var w in _allZoomWindows)
        {
            ConsoleLogger.Info($"  HWND=0x{w.Handle.ToInt64():X8} PID={w.ProcessId,-6} Visible={w.IsVisible,-5} Class='{w.ClassName,-30}' Title='{w.Title}' Bounds={w.Bounds}");
        }

        // 2. Run hooks + message pump on dedicated STA thread
        using var hooksReady = new ManualResetEventSlim(false);
        var localHooksReady = hooksReady;
        Exception? threadException = null;

        var watchThread = new Thread(() =>
        {
            try
            {
                RunMessagePumpWithHooks(timeoutSeconds, localHooksReady);
            }
            catch (Exception ex)
            {
                threadException = ex;
                localHooksReady.Set();
            }
        });
        watchThread.SetApartmentState(ApartmentState.STA);
        watchThread.IsBackground = true;
        watchThread.Start();

        hooksReady.Wait(TimeSpan.FromSeconds(15));
        watchThread.Join(TimeSpan.FromSeconds(timeoutSeconds + 15));

        if (threadException != null)
        {
            ConsoleLogger.Error($"Meeting watch thread error: {threadException.Message}");
            _diagnostics.Add($"Meeting watch thread error: {threadException.Message}");
        }

        return BuildResult();
    }

    private void RunMessagePumpWithHooks(int timeoutSeconds, ManualResetEventSlim hooksReady)
    {
        _messageThreadId = GetCurrentThreadId();
        _hookDelegate = OnWinEvent;
        var hooks = new List<IntPtr>();

        try
        {
            ConsoleLogger.Info("Installing WinEvent hooks for meeting discovery...");

            foreach (var pid in _zoomPids)
            {
                var h1 = SetWinEventHook(
                    EVENT_OBJECT_CREATE, EVENT_OBJECT_REORDER,
                    IntPtr.Zero, _hookDelegate,
                    (uint)pid, 0, WINEVENT_OUTOFCONTEXT);
                if (h1 != IntPtr.Zero) hooks.Add(h1);

                var h2 = SetWinEventHook(
                    EVENT_OBJECT_FOCUS, EVENT_OBJECT_VALUECHANGE,
                    IntPtr.Zero, _hookDelegate,
                    (uint)pid, 0, WINEVENT_OUTOFCONTEXT);
                if (h2 != IntPtr.Zero) hooks.Add(h2);
            }

            // Global: foreground changes & menu popup events
            var hFg = SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero, _hookDelegate,
                0, 0, WINEVENT_OUTOFCONTEXT);
            if (hFg != IntPtr.Zero) hooks.Add(hFg);

            var hMenu = SetWinEventHook(
                EVENT_SYSTEM_MENUPOPUPSTART, EVENT_SYSTEM_MENUPOPUPEND,
                IntPtr.Zero, _hookDelegate,
                0, 0, WINEVENT_OUTOFCONTEXT);
            if (hMenu != IntPtr.Zero) hooks.Add(hMenu);

            ConsoleLogger.Info($"Installed {hooks.Count} WinEvent hook(s).");
            _diagnostics.Add($"Installed {hooks.Count} WinEvent hook(s).");

            if (hooks.Count == 0)
            {
                ConsoleLogger.Error("FAILED to install WinEvent hooks.");
                _diagnostics.Add("FAILED to install WinEvent hooks.");
                hooksReady.Set();
                return;
            }

            hooksReady.Set();

            ConsoleLogger.Info("================================================================================");
            ConsoleLogger.Info($"  MEETING & WAITING ROOM WATCH ACTIVE ({timeoutSeconds}s)                       ");
            ConsoleLogger.Info("  1. Join/Start a Zoom meeting and open the Participants panel.                ");
            ConsoleLogger.Info("  2. Have a test participant enter the Waiting Room.                           ");
            ConsoleLogger.Info("  3. Keep Zoom foreground for part of the test (STATE A).                      ");
            ConsoleLogger.Info("  4. Switch foreground to Chrome or VS Code for part of the test (STATE B).    ");
            ConsoleLogger.Info("  * READ ONLY: The inspector will NOT click Admit.                             ");
            ConsoleLogger.Info("================================================================================");

            // Take initial snapshot
            TakeMeetingSnapshot("Initial capture");

            // Start a periodic background scanner that takes snapshots every 5 seconds
            using var cancelCts = new CancellationTokenSource();
            var periodicThread = new Thread(() =>
            {
                while (!cancelCts.Token.IsCancellationRequested)
                {
                    Thread.Sleep(5000);
                    if (cancelCts.Token.IsCancellationRequested) break;
                    TakeMeetingSnapshot("Periodic 5s poll");
                }
            });
            periodicThread.IsBackground = true;
            periodicThread.Start();

            // Timeout timer
            var savedThreadId = _messageThreadId;
            var timerThread = new Thread(() =>
            {
                Thread.Sleep(timeoutSeconds * 1000);
                cancelCts.Cancel();
                ConsoleLogger.Info("Meeting watch timeout reached.");
                _diagnostics.Add($"Watch timeout reached after {timeoutSeconds}s.");
                PostThreadMessage(savedThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            });
            timerThread.IsBackground = true;
            timerThread.Start();

            // Message pump
            int getMessageResult;
            while ((getMessageResult = GetMessageW(out var msg, IntPtr.Zero, 0, 0)) != 0)
            {
                if (getMessageResult == -1)
                {
                    var error = Marshal.GetLastWin32Error();
                    ConsoleLogger.Warn($"GetMessage returned -1 (Error: {error})");
                    continue;
                }

                TranslateMessage(ref msg);
                DispatchMessageW(ref msg);
            }
        }
        finally
        {
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
        if (hwnd == IntPtr.Zero) return;

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
        bool isZoomPid = _zoomPids.Contains((int)pid);
        bool isFgEvent = eventType == EVENT_SYSTEM_FOREGROUND;

        if (!isZoomPid && !isFgEvent)
        {
            return;
        }

        var evt = new WinEventProfileMenuWatcher.CapturedEvent(
            DateTime.Now, eventName, hwnd,
            idObject, idChild, pid,
            className, title, isVisible, bounds);

        lock (_lock)
        {
            _events.Add(evt);
        }

        var boundsStr = bounds != null ? $"{bounds.X},{bounds.Y} {bounds.Width}x{bounds.Height}" : "n/a";
        ConsoleLogger.Info($"[EVENT] {eventName,-26} HWND=0x{hwnd.ToInt64():X8} PID={pid,-6} Visible={isVisible,-5} Class='{className}' Title='{title}' Bounds=({boundsStr})");

        // When foreground changes or relevant object creation/reorder occurs, take snapshot
        if (isFgEvent || eventType is EVENT_OBJECT_SHOW or EVENT_OBJECT_CREATE or EVENT_OBJECT_REORDER or EVENT_OBJECT_NAMECHANGE)
        {
            TakeMeetingSnapshot($"Triggered by {eventName}");
        }
    }

    private void TakeMeetingSnapshot(string triggerReason)
    {
        try
        {
            var foreground = NativeMethods.GetForegroundWindowInfoSafe();
            bool isZoomForeground = _zoomPids.Contains(foreground.ProcessId);
            var zoomWindows = CaptureZoomWindows();

            using var automation = new UIA3Automation();
            var meetingTrees = new List<InspectElementInfo>();
            var waitingParticipants = new List<WaitingParticipantInfo>();
            var admitButtons = new List<InspectElementInfo>();
            var admitAllButtons = new List<InspectElementInfo>();

            // Find all meeting-candidate windows
            var targetHwnds = zoomWindows
                .Where(w => w.IsVisible && w.Bounds.Width > 0 && w.Bounds.Height > 0)
                .Select(w => w.Handle)
                .Distinct()
                .ToList();

            foreach (var hWnd in targetHwnds)
            {
                try
                {
                    var elem = automation.FromHandle(hWnd);
                    if (elem == null) continue;

                    int totalVisited = 0;
                    var tree = TraverseSubtree(elem, 0, _maxDepth, _maxElements, ref totalVisited);
                    if (tree != null)
                    {
                        meetingTrees.Add(tree);
                        ExtractWaitingRoomAndAdmit(tree, waitingParticipants, admitButtons, admitAllButtons);
                    }
                }
                catch (Exception ex)
                {
                    _diagnostics.Add($"Failed to inspect window 0x{hWnd.ToInt64():X}: {ex.Message}");
                }
            }

            var snapshot = new MeetingSnapshot(
                DateTime.Now,
                foreground,
                isZoomForeground,
                zoomWindows,
                meetingTrees,
                waitingParticipants,
                admitButtons,
                admitAllButtons
            );

            lock (_lock)
            {
                if (isZoomForeground)
                {
                    _foregroundSnapshots.Add(snapshot);
                }
                else
                {
                    _backgroundSnapshots.Add(snapshot);
                }
            }

            var stateLabel = isZoomForeground ? "STATE A (Zoom Foreground)" : $"STATE B (Background: '{foreground.ProcessName}')";
            ConsoleLogger.Info($"[SNAPSHOT] {stateLabel} | Reason: {triggerReason} | Windows: {meetingTrees.Count} | Waiting Participants: {waitingParticipants.Count} | Admit Buttons: {admitButtons.Count} | Admit All: {admitAllButtons.Count}");
        }
        catch (Exception ex)
        {
            ConsoleLogger.Debug($"Snapshot capture error: {ex.Message}");
        }
    }

    private static void ExtractWaitingRoomAndAdmit(
        InspectElementInfo element,
        List<WaitingParticipantInfo> waitingParticipants,
        List<InspectElementInfo> admitButtons,
        List<InspectElementInfo> admitAllButtons)
    {
        // Check for Admit All
        if (MeetingElementMatcher.IsAdmitAllButton(element.Name, element.LegacyName, element.ControlType))
        {
            admitAllButtons.Add(element);
        }
        // Check for Admit button
        else if (MeetingElementMatcher.IsAdmitButton(element.Name, element.LegacyName, element.ControlType))
        {
            admitButtons.Add(element);
        }

        // Check if this element represents a participant row in the waiting room
        bool hasAdmitChild = element.Children.Any(c => MeetingElementMatcher.IsAdmitButton(c.Name, c.LegacyName, c.ControlType));
        if (hasAdmitChild || element.Name.IndexOf("Waiting", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            var admitChild = element.Children.FirstOrDefault(c => MeetingElementMatcher.IsAdmitButton(c.Name, c.LegacyName, c.ControlType));
            var displayName = !string.IsNullOrWhiteSpace(element.Name) ? element.Name : element.LegacyName ?? "(unknown)";
            waitingParticipants.Add(new WaitingParticipantInfo(displayName, element.Name, element, admitChild));
        }

        foreach (var child in element.Children)
        {
            ExtractWaitingRoomAndAdmit(child, waitingParticipants, admitButtons, admitAllButtons);
        }
    }

    private InspectElementInfo? TraverseSubtree(
        AutomationElement element, int depth, int maxDepth, int maxElements, ref int totalVisited)
    {
        if (depth > maxDepth || totalVisited >= maxElements)
            return null;

        totalVisited++;
        var node = FlaUiElementExtractor.ExtractElementInfo(element, depth);

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

    private List<WindowSnapshot> CaptureZoomWindows()
    {
        var list = new List<WindowSnapshot>();
        NativeMethods.EnumWindows((hWnd, _) =>
        {
            NativeMethods.GetWindowThreadProcessId(hWnd, out var pid);
            if (_zoomPids.Contains((int)pid))
            {
                var cls = NativeMethods.GetClassNameSafe(hWnd);
                var title = NativeMethods.GetWindowTitleSafe(hWnd);
                bool isVisible = NativeMethods.IsWindowVisible(hWnd);
                NativeMethods.GetWindowRect(hWnd, out var r);

                string procName = "Zoom";
                try
                {
                    using var p = Process.GetProcessById((int)pid);
                    procName = p.ProcessName;
                }
                catch { }

                var bounds = new BoundingRectangleInfo(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
                list.Add(new WindowSnapshot(hWnd, (int)pid, procName, cls, title, isVisible, bounds));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    private MeetingWatchResult BuildResult()
    {
        return new MeetingWatchResult(
            _candidates,
            _allZoomWindows,
            _foregroundSnapshots.ToList(),
            _backgroundSnapshots.ToList(),
            _events.ToList(),
            _diagnostics.ToList()
        );
    }

    private static string EventName(uint eventType) => eventType switch
    {
        EVENT_OBJECT_CREATE => "EVENT_OBJECT_CREATE",
        EVENT_OBJECT_DESTROY => "EVENT_OBJECT_DESTROY",
        EVENT_OBJECT_SHOW => "EVENT_OBJECT_SHOW",
        EVENT_OBJECT_REORDER => "EVENT_OBJECT_REORDER",
        EVENT_OBJECT_FOCUS => "EVENT_OBJECT_FOCUS",
        EVENT_OBJECT_STATECHANGE => "EVENT_OBJECT_STATECHANGE",
        EVENT_OBJECT_NAMECHANGE => "EVENT_OBJECT_NAMECHANGE",
        EVENT_OBJECT_VALUECHANGE => "EVENT_OBJECT_VALUECHANGE",
        EVENT_SYSTEM_FOREGROUND => "EVENT_SYSTEM_FOREGROUND",
        EVENT_SYSTEM_MENUPOPUPSTART => "EVENT_SYSTEM_MENUPOPUPSTART",
        EVENT_SYSTEM_MENUPOPUPEND => "EVENT_SYSTEM_MENUPOPUPEND",
        _ => $"EVENT_0x{eventType:X4}"
    };
}
