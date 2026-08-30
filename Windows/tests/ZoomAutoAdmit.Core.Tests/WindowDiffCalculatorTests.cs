using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class WindowDiffCalculatorTests
{
    [Fact]
    public void CalculateDiff_IdentifiesNewWindow()
    {
        var before = new List<WindowSnapshot>
        {
            new(new IntPtr(0x100), 1000, "Zoom", "ZPPTMainFrmWndClassEx", "Zoom", true, new BoundingRectangleInfo(0, 0, 800, 600))
        };

        var after = new List<WindowSnapshot>
        {
            new(new IntPtr(0x100), 1000, "Zoom", "ZPPTMainFrmWndClassEx", "Zoom", true, new BoundingRectangleInfo(0, 0, 800, 600)),
            new(new IntPtr(0x200), 1000, "Zoom", "zCustomizedDrawMenuClass", "", true, new BoundingRectangleInfo(100, 100, 200, 300))
        };

        var targetPids = new HashSet<int> { 1000 };
        var diff = WindowDiffCalculator.CalculateDiff(before, after, targetPids);

        Assert.Single(diff.NewWindows);
        Assert.Equal(new IntPtr(0x200), diff.NewWindows[0].Handle);
        Assert.Single(diff.PrimaryCandidates);
        Assert.Equal(new IntPtr(0x200), diff.PrimaryCandidates[0].Handle);
    }

    [Fact]
    public void CalculateDiff_IdentifiesBecameVisibleWindow()
    {
        var before = new List<WindowSnapshot>
        {
            new(new IntPtr(0x100), 1000, "Zoom", "zCustomizedDrawMenuClass", "", false, new BoundingRectangleInfo(0, 0, 0, 0))
        };

        var after = new List<WindowSnapshot>
        {
            new(new IntPtr(0x100), 1000, "Zoom", "zCustomizedDrawMenuClass", "", true, new BoundingRectangleInfo(100, 100, 250, 400))
        };

        var targetPids = new HashSet<int> { 1000 };
        var diff = WindowDiffCalculator.CalculateDiff(before, after, targetPids);

        Assert.Empty(diff.NewWindows);
        Assert.Single(diff.BecameVisibleWindows);
        Assert.Single(diff.ResizedToNonZeroWindows);
        Assert.Single(diff.PrimaryCandidates);
        Assert.Equal(new IntPtr(0x100), diff.PrimaryCandidates[0].Handle);
    }

    [Fact]
    public void CalculateDiff_IgnoresHiddenOrZeroSizedPopupsInPrimaryCandidates()
    {
        var before = new List<WindowSnapshot>();
        var after = new List<WindowSnapshot>
        {
            new(new IntPtr(0x300), 1000, "Zoom", "ZPMenuClass", "", false, new BoundingRectangleInfo(0, 0, 0, 0))
        };

        var targetPids = new HashSet<int> { 1000 };
        var diff = WindowDiffCalculator.CalculateDiff(before, after, targetPids);

        Assert.Single(diff.NewWindows);
        Assert.Empty(diff.PrimaryCandidates);
    }
}
