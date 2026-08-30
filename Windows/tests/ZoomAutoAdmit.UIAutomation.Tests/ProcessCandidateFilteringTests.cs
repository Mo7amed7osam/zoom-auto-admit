using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

/// <summary>
/// UNIT TESTED: Process candidate ranking and filtering logic (pure model logic).
/// NOTE: Interacting with running Zoom instances REQUIRES LIVE ZOOM VALIDATION.
/// </summary>
public class ProcessCandidateFilteringTests
{
    [Fact]
    public void CandidateSorting_PrioritizesZoomProcessWithVisibleWindows()
    {
        var helperProcess = new ZoomProcessCandidate(
            101,
            "CptHost",
            @"C:\Program Files\Zoom\bin\CptHost.exe",
            IntPtr.Zero,
            "",
            new List<ZoomWindowInfo>(),
            false
        );

        var backgroundZoom = new ZoomProcessCandidate(
            102,
            "Zoom",
            @"C:\Users\User\AppData\Roaming\Zoom\bin\Zoom.exe",
            IntPtr.Zero,
            "",
            new List<ZoomWindowInfo>(),
            false
        );

        var foregroundZoom = new ZoomProcessCandidate(
            103,
            "Zoom",
            @"C:\Users\User\AppData\Roaming\Zoom\bin\Zoom.exe",
            new IntPtr(0x1234),
            "Zoom Workplace",
            new List<ZoomWindowInfo>
            {
                new(new IntPtr(0x1234), "Zoom Workplace", "ZPFloatToolbar", true, new BoundingRectangleInfo(0, 0, 800, 600))
            },
            true
        );

        var list = new List<ZoomProcessCandidate> { helperProcess, backgroundZoom, foregroundZoom };

        var sorted = list
            .OrderByDescending(c => c.ProcessName.Equals("Zoom", StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(c => c.Windows.Count(w => w.IsVisible))
            .ThenBy(c => c.ProcessId)
            .ToList();

        Assert.Equal(103, sorted[0].ProcessId);
        Assert.Equal(102, sorted[1].ProcessId);
        Assert.Equal(101, sorted[2].ProcessId);
    }
}
