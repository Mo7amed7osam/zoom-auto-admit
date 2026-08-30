using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

/// <summary>
/// UNIT TESTED: Verifies PatternSupportInfo and element safety models.
/// NOTE: Full UI Automation tree traversal on live desktop REQUIRES LIVE ZOOM VALIDATION.
/// </summary>
public class SafePropertyExtractionTests
{
    [Fact]
    public void PatternSupportInfo_GetSupportedPatternNames_ReturnsOnlyTruePatterns()
    {
        var patterns = new PatternSupportInfo
        {
            HasInvoke = true,
            HasToggle = false,
            HasExpandCollapse = true,
            HasLegacyIAccessible = true
        };

        var supported = patterns.GetSupportedPatternNames();

        Assert.Contains("InvokePattern", supported);
        Assert.Contains("ExpandCollapsePattern", supported);
        Assert.Contains("LegacyIAccessiblePattern", supported);
        Assert.DoesNotContain("TogglePattern", supported);
        Assert.DoesNotContain("ValuePattern", supported);
    }

    [Fact]
    public void InspectElementInfo_DefaultState_InitializesSafelyWithoutExceptions()
    {
        var element = new InspectElementInfo();

        Assert.NotNull(element.Children);
        Assert.Empty(element.Children);
        Assert.NotNull(element.Patterns);
        Assert.Null(element.IsEnabled);
        Assert.Null(element.IsOffscreen);
        Assert.Null(element.BoundingRectangle);
    }
}
