using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

public class AccountMenuInspector
{
    public record Result(
        ForegroundWindowInfo ForegroundBefore,
        ForegroundWindowInfo ForegroundAfter,
        bool StoleFocus,
        InspectElementInfo? ProfileButton,
        List<ZoomWindowInfo> DiscoveredPopupWindows,
        List<InspectElementInfo> PopupTrees,
        List<string> DiagnosticMessages
    );

    public Result InspectAccountMenu(int? targetPid = null)
    {
        ForegroundWindowInfo fgBefore = new(IntPtr.Zero, 0, "(none)", "");
        ForegroundWindowInfo fgAfter = new(IntPtr.Zero, 0, "(none)", "");
        bool stoleFocus = false;
        InspectElementInfo? profileButtonInfo = null;
        var popupWindows = new List<ZoomWindowInfo>();
        var popupTrees = new List<InspectElementInfo>();
        var diagnostics = new List<string>();

        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            // 1. Record foreground window BEFORE
            fgBefore = NativeMethods.GetForegroundWindowInfoSafe();
            diagnostics.Add($"Foreground BEFORE: PID={fgBefore.ProcessId}, Name='{fgBefore.ProcessName}', HWND=0x{fgBefore.Handle.ToInt64():X}, Title='{fgBefore.WindowTitle}'");

            using var automation = new UIA3Automation();
            var candidates = new ZoomProcessDiscovery().FindCandidates();
            var zoomPids = candidates.Select(c => c.ProcessId).ToHashSet();

            if (targetPid.HasValue)
            {
                zoomPids = new HashSet<int> { targetPid.Value };
            }

            if (zoomPids.Count == 0)
            {
                diagnostics.Add("No Zoom Workplace processes found.");
                return;
            }

            // 2. Find main Zoom Workplace window
            var preExistingHwnds = new HashSet<IntPtr>();
            var candidateHwnds = new List<IntPtr>();

            NativeMethods.EnumWindows((hWnd, _) =>
            {
                if (NativeMethods.IsWindowVisible(hWnd))
                {
                    NativeMethods.GetWindowThreadProcessId(hWnd, out var wPid);
                    if (zoomPids.Contains((int)wPid))
                    {
                        preExistingHwnds.Add(hWnd);
                        var cls = NativeMethods.GetClassNameSafe(hWnd);
                        if (cls.IndexOf("MainFrm", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            cls.IndexOf("ZPPT", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            candidateHwnds.Add(hWnd);
                        }
                    }
                }
                return true;
            }, IntPtr.Zero);

            if (candidateHwnds.Count == 0)
            {
                candidateHwnds.AddRange(preExistingHwnds);
            }

            if (candidateHwnds.Count == 0)
            {
                diagnostics.Add("No visible Zoom Workplace top-level window found.");
                return;
            }

            // 3. Find and verify profile SplitButton structurally
            AutomationElement? targetProfileButton = null;

            foreach (var hWnd in candidateHwnds)
            {
                try
                {
                    var mainWin = automation.FromHandle(hWnd);
                    if (mainWin == null) continue;

                    targetProfileButton = FindProfileButtonRecursive(mainWin, zoomPids);
                    if (targetProfileButton != null)
                    {
                        break;
                    }
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"Error searching window 0x{hWnd.ToInt64():X}: {ex.Message}");
                }
            }

            if (targetProfileButton == null)
            {
                diagnostics.Add("Profile SplitButton matching safety requirements was not found in Zoom main window.");
                return;
            }

            // 4. Extract verified Profile Button info
            profileButtonInfo = FlaUiElementExtractor.ExtractElementInfo(targetProfileButton, 0);
            diagnostics.Add($"Verified Profile Button: '{profileButtonInfo.Name}' [CT: {profileButtonInfo.ControlType}, PID: {profileButtonInfo.ProcessId}]");

            // 5. Inspect patterns and children on profile SplitButton
            var profileChildren = targetProfileButton.FindAllChildren();
            diagnostics.Add($"Profile Button has {profileChildren.Length} child element(s).");
            foreach (var ch in profileChildren)
            {
                var chInfo = FlaUiElementExtractor.ExtractElementInfo(ch, 1);
                var pats = string.Join(", ", chInfo.Patterns.GetSupportedPatternNames());
                diagnostics.Add($"  -> Child: [{chInfo.ControlType}] '{chInfo.Name}' Patterns=[{pats}] Bounds={chInfo.BoundingRectangle}");
            }

            diagnostics.Add("Invoking Profile SplitButton via UIA InvokePattern / LegacyIAccessible / ExpandCollapse...");
            bool invoked = false;

            // Try ExpandCollapse if supported
            if (!invoked && targetProfileButton.Patterns.ExpandCollapse.IsSupported)
            {
                try
                {
                    targetProfileButton.Patterns.ExpandCollapse.Pattern.Expand();
                    invoked = true;
                    diagnostics.Add("Invoked successfully via ExpandCollapsePattern.Expand().");
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"ExpandCollapsePattern.Expand() failed: {ex.Message}");
                }
            }

            // Try InvokePattern
            if (!invoked && targetProfileButton.Patterns.Invoke.IsSupported)
            {
                try
                {
                    targetProfileButton.Patterns.Invoke.Pattern.Invoke();
                    invoked = true;
                    diagnostics.Add("Invoked successfully via InvokePattern.Invoke().");
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"InvokePattern.Invoke() failed: {ex.Message}");
                }
            }

            // Try LegacyIAccessible DoDefaultAction
            if (!invoked && targetProfileButton.Patterns.LegacyIAccessible.IsSupported)
            {
                try
                {
                    targetProfileButton.Patterns.LegacyIAccessible.Pattern.DoDefaultAction();
                    invoked = true;
                    diagnostics.Add("Invoked successfully via LegacyIAccessible.DoDefaultAction().");
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"LegacyIAccessible.DoDefaultAction() failed: {ex.Message}");
                }
            }

            // Try children if parent split button delegates action to a child dropdown/button
            if (!invoked)
            {
                foreach (var ch in profileChildren)
                {
                    try
                    {
                        if (ch.Patterns.Invoke.IsSupported)
                        {
                            ch.Patterns.Invoke.Pattern.Invoke();
                            invoked = true;
                            diagnostics.Add($"Invoked successfully via Child [{ch.Properties.ControlType.Value}] InvokePattern.Invoke().");
                            break;
                        }
                        if (ch.Patterns.ExpandCollapse.IsSupported)
                        {
                            ch.Patterns.ExpandCollapse.Pattern.Expand();
                            invoked = true;
                            diagnostics.Add($"Invoked successfully via Child [{ch.Properties.ControlType.Value}] ExpandCollapsePattern.Expand().");
                            break;
                        }
                        if (ch.Patterns.LegacyIAccessible.IsSupported)
                        {
                            ch.Patterns.LegacyIAccessible.Pattern.DoDefaultAction();
                            invoked = true;
                            diagnostics.Add($"Invoked successfully via Child [{ch.Properties.ControlType.Value}] LegacyIAccessible.DoDefaultAction().");
                            break;
                        }
                    }
                    catch (Exception ex)
                    {
                        diagnostics.Add($"Child invocation attempt failed: {ex.Message}");
                    }
                }
            }

            // Wait briefly for the popup menu to be created
            Thread.Sleep(500);

            // 6. Record foreground window AFTER
            fgAfter = NativeMethods.GetForegroundWindowInfoSafe();
            stoleFocus = (fgBefore.Handle != fgAfter.Handle && zoomPids.Contains(fgAfter.ProcessId));
            diagnostics.Add($"Foreground AFTER: PID={fgAfter.ProcessId}, Name='{fgAfter.ProcessName}', HWND=0x{fgAfter.Handle.ToInt64():X}, Title='{fgAfter.WindowTitle}'");
            diagnostics.Add($"Focus change detected: {(fgBefore.Handle != fgAfter.Handle ? "YES" : "NO")} | Zoom stole foreground: {(stoleFocus ? "YES" : "NO")}");

            // 7. Discover newly created popup windows or Zoom menu windows
            var postHwnds = new List<IntPtr>();
            NativeMethods.EnumWindows((hWnd, _) =>
            {
                if (NativeMethods.IsWindowVisible(hWnd))
                {
                    NativeMethods.GetWindowThreadProcessId(hWnd, out var wPid);
                    var cls = NativeMethods.GetClassNameSafe(hWnd);
                    var title = NativeMethods.GetWindowTitleSafe(hWnd);

                    bool isZoomPid = zoomPids.Contains((int)wPid);
                    bool isMenuClass = cls.StartsWith("zCustomized", StringComparison.OrdinalIgnoreCase) ||
                                       cls.StartsWith("ZPMenu", StringComparison.OrdinalIgnoreCase) ||
                                       cls.StartsWith("PopupContainer", StringComparison.OrdinalIgnoreCase) ||
                                       cls.StartsWith("ZAic", StringComparison.OrdinalIgnoreCase);

                    if ((isZoomPid && !preExistingHwnds.Contains(hWnd)) || (isZoomPid && isMenuClass))
                    {
                        postHwnds.Add(hWnd);
                        NativeMethods.GetWindowRect(hWnd, out var rect);
                        popupWindows.Add(new ZoomWindowInfo(hWnd, title, cls, true, rect.ToBoundingRectangle()));
                    }
                }
                return true;
            }, IntPtr.Zero);

            diagnostics.Add($"Discovered {postHwnds.Count} popup HWND(s) associated with Zoom profile menu.");

            // 8. Enumerate popup UIA hierarchy from discovered HWNDs and desktop children
            var popupElements = new List<AutomationElement>();
            foreach (var hWnd in postHwnds)
            {
                try
                {
                    var elem = automation.FromHandle(hWnd);
                    if (elem != null)
                    {
                        popupElements.Add(elem);
                    }
                }
                catch (Exception ex)
                {
                    diagnostics.Add($"Failed to bind UIA for popup HWND 0x{hWnd.ToInt64():X}: {ex.Message}");
                }
            }

            // Also check desktop direct children with menu control type
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

                        if (zoomPids.Contains(childPid) && (childCt == ControlType.Menu || childCt == ControlType.Window || childCls.StartsWith("zCustomized") || childCls.StartsWith("ZPMenu")))
                        {
                            if (!popupElements.Any(p => {
                                try { return p.Properties.NativeWindowHandle.ValueOrDefault == child.Properties.NativeWindowHandle.ValueOrDefault; } catch { return false; }
                            }))
                            {
                                popupElements.Add(child);
                            }
                        }
                    }
                    catch { }
                }
            }
            catch (Exception ex)
            {
                diagnostics.Add($"Desktop children check exception: {ex.Message}");
            }

            // 9. Traverse and extract full hierarchy for each popup
            int totalVisited = 0;
            int maxDepth = 25;
            foreach (var popupElem in popupElements)
            {
                var tree = TraversePopupSubtree(popupElem, 0, maxDepth, ref totalVisited);
                if (tree != null)
                {
                    popupTrees.Add(tree);
                }
            }

            diagnostics.Add($"Extracted {popupTrees.Count} popup tree(s) with {totalVisited} total elements.");
        });

        return new Result(fgBefore, fgAfter, stoleFocus, profileButtonInfo, popupWindows, popupTrees, diagnostics);
    }

    private static AutomationElement? FindProfileButtonRecursive(AutomationElement element, HashSet<int> validPids)
    {
        try
        {
            var pid = element.Properties.ProcessId.ValueOrDefault;
            if (!validPids.Contains(pid))
            {
                return null;
            }

            var ct = element.Properties.ControlType.ValueOrDefault.ToString();
            var name = element.Properties.Name.ValueOrDefault ?? string.Empty;
            var isEnabled = element.Properties.IsEnabled.ValueOrDefault;
            var hasInvoke = element.Patterns.Invoke.IsSupported;

            if (ProfileButtonMatcher.IsProfileSplitButton(ct, name, isEnabled, hasInvoke))
            {
                return element;
            }

            var children = element.FindAllChildren();
            foreach (var child in children)
            {
                var match = FindProfileButtonRecursive(child, validPids);
                if (match != null)
                {
                    return match;
                }
            }
        }
        catch { }

        return null;
    }

    private static InspectElementInfo? TraversePopupSubtree(AutomationElement element, int depth, int maxDepth, ref int totalVisited)
    {
        if (depth > maxDepth || totalVisited > 1000)
        {
            return null;
        }

        totalVisited++;
        var node = FlaUiElementExtractor.ExtractElementInfo(element, depth);

        try
        {
            var children = element.FindAllChildren();
            foreach (var child in children)
            {
                var childNode = TraversePopupSubtree(child, depth + 1, maxDepth, ref totalVisited);
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
