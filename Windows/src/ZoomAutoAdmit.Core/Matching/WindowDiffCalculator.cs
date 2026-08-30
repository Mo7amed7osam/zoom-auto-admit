using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public static class WindowDiffCalculator
{
    private static readonly HashSet<string> KnownPopupClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "zCustomizedDrawMenuClass",
        "ZPMenuClass",
        "PopupContainerBase",
        "ZAicPlusPtPopupContainerWndClass",
        "ZPPTEnhanceLoginMainWindowClassEx",
        "ZPFloatControlPanelMgrClass"
    };

    public static WindowDiffResult CalculateDiff(
        IReadOnlyList<WindowSnapshot> before,
        IReadOnlyList<WindowSnapshot> after,
        IReadOnlySet<int>? targetPids = null)
    {
        var beforeMap = before.ToDictionary(w => w.Handle, w => w);

        var newWindows = new List<WindowSnapshot>();
        var becameVisible = new List<WindowSnapshot>();
        var resizedNonZero = new List<WindowSnapshot>();

        foreach (var win in after)
        {
            if (!beforeMap.TryGetValue(win.Handle, out var prev))
            {
                newWindows.Add(win);
            }
            else
            {
                if (!prev.IsVisible && win.IsVisible)
                {
                    becameVisible.Add(win);
                }

                bool wasZero = (prev.Bounds.Width <= 0 || prev.Bounds.Height <= 0);
                bool isNonZero = (win.Bounds.Width > 0 && win.Bounds.Height > 0);

                if (wasZero && isNonZero)
                {
                    resizedNonZero.Add(win);
                }
            }
        }

        // Primary candidates:
        // Must be visible, width > 0, height > 0
        // And either:
        // 1. In newWindows, becameVisible, or resizedNonZero
        // 2. Owned by target Zoom PID
        // 3. Known Zoom popup class
        var candidateSet = new HashSet<IntPtr>();
        var primaryCandidates = new List<WindowSnapshot>();

        void AddCandidateIfEligible(WindowSnapshot win)
        {
            if (candidateSet.Contains(win.Handle)) return;

            bool hasValidBounds = win.IsVisible && win.Bounds.Width > 0 && win.Bounds.Height > 0;
            if (!hasValidBounds) return;

            bool isZoomPid = targetPids == null || targetPids.Contains(win.ProcessId);
            bool isKnownClass = IsKnownPopupClass(win.ClassName);

            if (isZoomPid || isKnownClass)
            {
                candidateSet.Add(win.Handle);
                primaryCandidates.Add(win);
            }
        }

        // Add dynamically changed windows first
        foreach (var w in newWindows) AddCandidateIfEligible(w);
        foreach (var w in becameVisible) AddCandidateIfEligible(w);
        foreach (var w in resizedNonZero) AddCandidateIfEligible(w);

        // Also check if any after window is a visible known popup with non-zero bounds
        foreach (var w in after)
        {
            if (IsKnownPopupClass(w.ClassName))
            {
                AddCandidateIfEligible(w);
            }
        }

        return new WindowDiffResult(newWindows, becameVisible, resizedNonZero, primaryCandidates);
    }

    public static bool IsKnownPopupClass(string className)
    {
        if (string.IsNullOrWhiteSpace(className)) return false;

        foreach (var prefix in KnownPopupClasses)
        {
            if (className.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }
}
