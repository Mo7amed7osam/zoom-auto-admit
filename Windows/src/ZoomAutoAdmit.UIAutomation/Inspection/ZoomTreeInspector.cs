using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Filtering;
using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Interop;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

public class ZoomTreeInspector : IDisposable
{
    private readonly ZoomProcessDiscovery _processDiscovery;
    private bool _disposed;

    public ZoomTreeInspector()
    {
        _processDiscovery = new ZoomProcessDiscovery();
    }

    public (IReadOnlyList<InspectElementInfo> Roots, InspectionSummary Summary) Inspect(InspectionOptions options)
    {
        var stopwatch = Stopwatch.StartNew();
        var candidate = _processDiscovery.FindPrimaryCandidate(options.TargetProcessId);

        if (candidate == null)
        {
            ConsoleLogger.Warn("No candidate Zoom process found to inspect.");
            return (Array.Empty<InspectElementInfo>(), new InspectionSummary(0, 0, 0, false, false, stopwatch.Elapsed, new[] { "No Zoom process found" }));
        }

        var candidatePids = options.TargetProcessId.HasValue
            ? new HashSet<int> { options.TargetProcessId.Value }
            : _processDiscovery.FindCandidates().Select(c => c.ProcessId).ToHashSet();

        ConsoleLogger.Info($"Connecting UIA3 across candidate Zoom process PIDs: [{string.Join(", ", candidatePids)}]...");

        var rootElements = new List<InspectElementInfo>();
        var warnings = new List<string>();
        int totalVisited = 0;
        int maxDepthReached = 0;
        bool depthTruncated = false;
        bool countTruncated = false;

        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            using var automation = new UIA3Automation();
            try
            {
                var discoveredWindows = new List<AutomationElement>();
                var windowHandles = new List<IntPtr>();
                NativeMethods.EnumWindows((hWnd, _) =>
                {
                    if (NativeMethods.IsWindowVisible(hWnd))
                    {
                        NativeMethods.GetWindowThreadProcessId(hWnd, out var wPid);
                        var cls = NativeMethods.GetClassNameSafe(hWnd);
                        if (candidatePids.Contains((int)wPid) || 
                            cls.StartsWith("ZPMenuClass", StringComparison.OrdinalIgnoreCase) || 
                            cls.StartsWith("zCustomizedDrawMenuClass", StringComparison.OrdinalIgnoreCase) || 
                            cls.StartsWith("PopupContainerBase", StringComparison.OrdinalIgnoreCase))
                        {
                            windowHandles.Add(hWnd);
                        }
                    }
                    return true;
                }, IntPtr.Zero);

                ConsoleLogger.Info($"EnumWindows found {windowHandles.Count} candidate HWND(s) on desktop.");

                foreach (var hWnd in windowHandles)
                {
                    try
                    {
                        var elem = automation.FromHandle(hWnd);
                        if (elem != null)
                        {
                            discoveredWindows.Add(elem);
                        }
                    }
                    catch (Exception ex)
                    {
                        ConsoleLogger.Debug($"Failed to bind automation element from HWND 0x{hWnd.ToInt64():X}: {ex.Message}");
                    }
                }

                try
                {
                    var desktopChildren = automation.GetDesktop().FindAllChildren();
                    foreach (var child in desktopChildren)
                    {
                        try
                        {
                            var childPid = child.Properties.ProcessId.ValueOrDefault;
                            var childCls = child.Properties.ClassName.ValueOrDefault ?? "";
                            var childName = child.Properties.Name.ValueOrDefault ?? "";
                            if (candidatePids.Contains(childPid) || 
                                childCls.StartsWith("ZP", StringComparison.OrdinalIgnoreCase) || 
                                childCls.StartsWith("zCustomized", StringComparison.OrdinalIgnoreCase) || 
                                childCls.StartsWith("Popup", StringComparison.OrdinalIgnoreCase))
                            {
                                discoveredWindows.Add(child);
                            }
                        }
                        catch { }
                    }
                }
                catch (Exception ex)
                {
                    ConsoleLogger.Debug($"Desktop children enumeration error: {ex.Message}");
                }

                if (discoveredWindows.Count == 0)
                {
                    foreach (var pid in candidatePids)
                    {
                        try
                        {
                            var app = FlaUI.Core.Application.Attach(pid);
                            var appWindows = app.GetAllTopLevelWindows(automation);
                            discoveredWindows.AddRange(appWindows);
                        }
                        catch { }
                    }
                }

                var topLevelWindows = discoveredWindows.DistinctBy(w => {
                    try { return w.Properties.NativeWindowHandle.ValueOrDefault; } catch { return IntPtr.Zero; }
                }).ToArray();

                ConsoleLogger.Info($"Discovered {topLevelWindows.Length} matching top-level UIA window(s).");
                foreach (var win in topLevelWindows)
                {
                    try
                    {
                        var name = win.Properties.Name.ValueOrDefault ?? "(no name)";
                        var pid = win.Properties.ProcessId.ValueOrDefault;
                        var cls = win.Properties.ClassName.ValueOrDefault ?? "";
                        ConsoleLogger.Info($"  -> Candidate Window: '{name}' [Class: {cls}, PID: {pid}]");
                    }
                    catch { }
                }

                foreach (var topWindow in topLevelWindows)
                {
                    if (totalVisited >= options.MaxElements)
                    {
                        countTruncated = true;
                        ConsoleLogger.Warn($"Element limit of {options.MaxElements} reached. Halting traversal.");
                        break;
                    }

                    var rootNode = TraverseElement(
                        topWindow,
                        depth: 0,
                        options,
                        ref totalVisited,
                        ref maxDepthReached,
                        ref depthTruncated,
                        ref countTruncated,
                        warnings);

                    if (rootNode != null)
                    {
                        rootElements.Add(rootNode);
                    }
                }
            }
            catch (Exception ex)
            {
                ConsoleLogger.Error($"Critical error during UIA tree inspection: {ex.Message}");
                warnings.Add($"UIA Inspection exception: {ex.Message}");
            }
        });

        stopwatch.Stop();

        int matchedCount = 0;
        if (!string.IsNullOrWhiteSpace(options.SearchFilter))
        {
            foreach (var root in rootElements)
            {
                matchedCount += ElementFilter.FindMatches(root, options.SearchFilter).Count;
            }
        }
        else
        {
            matchedCount = totalVisited;
        }

        ConsoleLogger.Info($"Inspection complete. Visited {totalVisited} elements (Max depth reached: {maxDepthReached}) in {stopwatch.ElapsedMilliseconds} ms.");

        var summary = new InspectionSummary(
            totalVisited,
            matchedCount,
            maxDepthReached,
            depthTruncated,
            countTruncated,
            stopwatch.Elapsed,
            warnings
        );

        return (rootElements, summary);
    }

    private InspectElementInfo? TraverseElement(
        AutomationElement element,
        int depth,
        InspectionOptions options,
        ref int totalVisited,
        ref int maxDepthReached,
        ref bool depthTruncated,
        ref bool countTruncated,
        List<string> warnings)
    {
        if (totalVisited >= options.MaxElements)
        {
            countTruncated = true;
            return null;
        }

        totalVisited++;
        if (depth > maxDepthReached)
        {
            maxDepthReached = depth;
        }

        InspectElementInfo node;
        try
        {
            node = FlaUiElementExtractor.ExtractElementInfo(element, depth);
        }
        catch (Exception ex)
        {
            warnings.Add($"Error extracting node at depth {depth}: {ex.Message}");
            return new InspectElementInfo
            {
                Depth = depth,
                DiagnosticError = ex.Message
            };
        }

        if (depth >= options.MaxDepth)
        {
            depthTruncated = true;
            return node;
        }

        try
        {
            var children = element.FindAllChildren();
            foreach (var child in children)
            {
                if (totalVisited >= options.MaxElements)
                {
                    countTruncated = true;
                    break;
                }

                var childNode = TraverseElement(
                    child,
                    depth + 1,
                    options,
                    ref totalVisited,
                    ref maxDepthReached,
                    ref depthTruncated,
                    ref countTruncated,
                    warnings);

                if (childNode != null)
                {
                    node.Children.Add(childNode);
                }
            }
        }
        catch (Exception ex)
        {
            var warning = $"Failed to enumerate children for element [{node.ControlType} '{node.Name}']: {ex.Message}";
            warnings.Add(warning);
            node.DiagnosticError = warning;
        }

        return node;
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
        }
    }
}
