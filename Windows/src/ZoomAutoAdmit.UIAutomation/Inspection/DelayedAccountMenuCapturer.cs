using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

public class DelayedAccountMenuCapturer
{
    public record CaptureResult(
        ForegroundWindowInfo ForegroundWindow,
        List<WindowSnapshot> BeforeWindows,
        List<WindowSnapshot> AfterWindows,
        WindowDiffResult DiffResult,
        List<InspectElementInfo> PopupTrees,
        List<string> ExtractedTexts,
        List<string> Diagnostics
    );

    public CaptureResult Capture(int delaySeconds, int? targetPid = null, int maxDepth = 25, int maxElements = 1500)
    {
        var diagnostics = new List<string>();
        var beforeSnapshots = new List<WindowSnapshot>();
        var afterSnapshots = new List<WindowSnapshot>();
        var popupTrees = new List<InspectElementInfo>();
        var extractedTexts = new List<string>();
        ForegroundWindowInfo foreground = new(IntPtr.Zero, 0, "(none)", "");

        var candidates = new ZoomProcessDiscovery().FindCandidates();
        var zoomPids = candidates.Select(c => c.ProcessId).ToHashSet();

        if (targetPid.HasValue)
        {
            zoomPids = new HashSet<int> { targetPid.Value };
        }

        if (zoomPids.Count == 0)
        {
            diagnostics.Add("No Zoom Workplace processes found.");
            var emptyDiff = new WindowDiffResult(new(), new(), new(), new());
            return new CaptureResult(foreground, beforeSnapshots, afterSnapshots, emptyDiff, popupTrees, extractedTexts, diagnostics);
        }

        diagnostics.Add($"Target Zoom Process PIDs: [{string.Join(", ", zoomPids)}]");

        // 1. Capture BASELINE BEFORE countdown
        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            beforeSnapshots = CaptureAllTopLevelWindows();
        });
        diagnostics.Add($"Baseline BEFORE: captured {beforeSnapshots.Count} total top-level window(s).");

        // 2. Prompt user and wait
        ConsoleLogger.Info("================================================================================");
        ConsoleLogger.Info("  Open the Zoom profile menu manually now and leave it open.                    ");
        ConsoleLogger.Info($"  Capture will occur in {delaySeconds} seconds...                               ");
        ConsoleLogger.Info("================================================================================");

        for (int i = delaySeconds; i > 0; i--)
        {
            ConsoleLogger.Info($"Waiting... {i}s remaining (leave the profile menu open)");
            Thread.Sleep(1000);
        }

        ConsoleLogger.Info("Delay completed. Capturing AFTER state and popup UI Automation trees...");

        WindowDiffResult diffResult = new(new(), new(), new(), new());

        // 3. Capture AFTER state and attach UIA
        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            foreground = NativeMethods.GetForegroundWindowInfoSafe();
            diagnostics.Add($"Foreground at capture: PID={foreground.ProcessId}, Name='{foreground.ProcessName}', HWND=0x{foreground.Handle.ToInt64():X}, Title='{foreground.WindowTitle}'");

            afterSnapshots = CaptureAllTopLevelWindows();
            diagnostics.Add($"State AFTER: captured {afterSnapshots.Count} total top-level window(s).");

            diffResult = WindowDiffCalculator.CalculateDiff(beforeSnapshots, afterSnapshots, zoomPids);

            diagnostics.Add($"Diff Result: New={diffResult.NewWindows.Count}, BecameVisible={diffResult.BecameVisibleWindows.Count}, ResizedNonZero={diffResult.ResizedToNonZeroWindows.Count}, PrimaryCandidates={diffResult.PrimaryCandidates.Count}");

            using var automation = new UIA3Automation();
            var targetHwnds = new List<IntPtr>();

            // Prioritize primary candidates from the diff
            foreach (var c in diffResult.PrimaryCandidates)
            {
                targetHwnds.Add(c.Handle);
            }

            // Also check if any known popup classes exist in after
            foreach (var w in afterSnapshots)
            {
                if (WindowDiffCalculator.IsKnownPopupClass(w.ClassName) && w.IsVisible && w.Bounds.Width > 0 && w.Bounds.Height > 0)
                {
                    if (!targetHwnds.Contains(w.Handle))
                    {
                        targetHwnds.Add(w.Handle);
                    }
                }
            }

            // If no popup candidate found, also include the main Zoom window
            if (targetHwnds.Count == 0)
            {
                foreach (var w in afterSnapshots)
                {
                    if (zoomPids.Contains(w.ProcessId) && w.IsVisible && w.Bounds.Width > 0)
                    {
                        targetHwnds.Add(w.Handle);
                    }
                }
            }

            diagnostics.Add($"Target HWND(s) for UIA extraction: [{string.Join(", ", targetHwnds.Select(h => $"0x{h.ToInt64():X}"))}]");

            var uiaRoots = new List<AutomationElement>();
            foreach (var hWnd in targetHwnds)
            {
                try
                {
                    var elem = automation.FromHandle(hWnd);
                    if (elem != null)
                    {
                        uiaRoots.Add(elem);
                    }
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"Could not bind UIA element from HWND 0x{hWnd.ToInt64():X}: {ex.Message}");
                }
            }

            // Also check direct UIA Desktop children
            try
            {
                var desktopChildren = automation.GetDesktop().FindAllChildren();
                foreach (var child in desktopChildren)
                {
                    try
                    {
                        var childPid = child.Properties.ProcessId.ValueOrDefault;
                        var childCls = child.Properties.ClassName.ValueOrDefault ?? "";
                        var childCt = child.Properties.ControlType.ValueOrDefault;

                        bool isCandidate = (zoomPids.Contains(childPid) ||
                                           childCt == ControlType.Menu ||
                                           WindowDiffCalculator.IsKnownPopupClass(childCls));

                        if (isCandidate)
                        {
                            var h = child.Properties.NativeWindowHandle.ValueOrDefault;
                            if (h != IntPtr.Zero && !uiaRoots.Any(r => {
                                try { return r.Properties.NativeWindowHandle.ValueOrDefault == h; } catch { return false; }
                            }))
                            {
                                uiaRoots.Add(child);
                            }
                        }
                    }
                    catch { }
                }
            }
            catch (Exception ex)
            {
                diagnostics.Add($"Desktop children scan error: {ex.Message}");
            }

            int totalVisited = 0;
            var textSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var root in uiaRoots)
            {
                if (totalVisited >= maxElements) break;

                var tree = TraverseSubtree(root, 0, maxDepth, maxElements, ref totalVisited, textSet);
                if (tree != null)
                {
                    popupTrees.Add(tree);
                }
            }

            extractedTexts = textSet.Where(t => !string.IsNullOrWhiteSpace(t)).ToList();
            diagnostics.Add($"Captured {popupTrees.Count} tree(s) with {totalVisited} elements. Extracted {extractedTexts.Count} distinct text label(s).");
        });

        return new CaptureResult(foreground, beforeSnapshots, afterSnapshots, diffResult, popupTrees, extractedTexts, diagnostics);
    }

    private static List<WindowSnapshot> CaptureAllTopLevelWindows()
    {
        var list = new List<WindowSnapshot>();
        NativeMethods.EnumWindows((hWnd, _) =>
        {
            NativeMethods.GetWindowThreadProcessId(hWnd, out var pid);
            var cls = NativeMethods.GetClassNameSafe(hWnd);
            var title = NativeMethods.GetWindowTitleSafe(hWnd);
            bool isVisible = NativeMethods.IsWindowVisible(hWnd);
            NativeMethods.GetWindowRect(hWnd, out var r);

            string procName = "(unknown)";
            try
            {
                using var p = Process.GetProcessById((int)pid);
                procName = p.ProcessName;
            }
            catch { }

            var bounds = new BoundingRectangleInfo(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            list.Add(new WindowSnapshot(hWnd, (int)pid, procName, cls, title, isVisible, bounds));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    private static InspectElementInfo? TraverseSubtree(
        AutomationElement element,
        int depth,
        int maxDepth,
        int maxElements,
        ref int totalVisited,
        HashSet<string> textSet)
    {
        if (depth > maxDepth || totalVisited >= maxElements)
        {
            return null;
        }

        totalVisited++;
        var node = FlaUiElementExtractor.ExtractElementInfo(element, depth);

        if (!string.IsNullOrWhiteSpace(node.Name))
        {
            textSet.Add(node.Name.Trim());
        }
        if (!string.IsNullOrWhiteSpace(node.LegacyName))
        {
            textSet.Add(node.LegacyName.Trim());
        }
        if (!string.IsNullOrWhiteSpace(node.Value))
        {
            textSet.Add(node.Value.Trim());
        }

        try
        {
            var children = element.FindAllChildren();
            foreach (var child in children)
            {
                var childNode = TraverseSubtree(child, depth + 1, maxDepth, maxElements, ref totalVisited, textSet);
                if (childNode != null)
                {
                    node.Children.Add(childNode);
                }
            }
        }
        catch (Exception ex)
        {
            node.DiagnosticError = ex.Message;
        }

        return node;
    }
}
