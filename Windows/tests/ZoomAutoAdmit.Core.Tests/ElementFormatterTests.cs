using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

/// <summary>
/// UNIT TESTED: Tests for ElementFormatter logic (does not require live Zoom).
/// </summary>
public class ElementFormatterTests
{
    [Fact]
    public void FormatSingleElement_WithCompleteProperties_FormatsCorrectly()
    {
        var element = new InspectElementInfo
        {
            ControlType = "Button",
            Name = "Admit",
            AutomationId = "admit_btn_1",
            ClassName = "ZPButton",
            FrameworkType = "Win32",
            IsEnabled = true,
            IsOffscreen = false,
            BoundingRectangle = new BoundingRectangleInfo(100, 200, 80, 30),
            ProcessId = 1234,
            Patterns = new PatternSupportInfo
            {
                HasInvoke = true,
                HasLegacyIAccessible = true
            }
        };

        var output = ElementFormatter.FormatSingleElement(element);

        Assert.Contains("[Button]", output);
        Assert.Contains("Name: Admit", output);
        Assert.Contains("AutomationId: admit_btn_1", output);
        Assert.Contains("ClassName: ZPButton", output);
        Assert.Contains("Enabled: True", output);
        Assert.Contains("Offscreen: False", output);
        Assert.Contains("BoundingRectangle: [100, 200, 80x30]", output);
        Assert.Contains("InvokePattern: yes", output);
        Assert.Contains("LegacyIAccessiblePattern: yes", output);
    }

    [Fact]
    public void FormatSingleElement_WithMissingAndNullProperties_HandlesGracefullyWithoutThrowing()
    {
        var element = new InspectElementInfo
        {
            ControlType = "",
            Name = "",
            AutomationId = "",
            ClassName = "",
            IsEnabled = null,
            IsOffscreen = null,
            BoundingRectangle = null,
            ProcessId = 0
        };

        var output = ElementFormatter.FormatSingleElement(element);

        Assert.Contains("[Unknown]", output);
        Assert.Contains("Name: (empty)", output);
        Assert.Contains("AutomationId: (empty)", output);
        Assert.Contains("ClassName: (empty)", output);
        Assert.Contains("Enabled: unknown", output);
        Assert.Contains("Offscreen: unknown", output);
        Assert.Contains("Patterns: (none detected)", output);
    }

    [Fact]
    public void FormatTree_WithNestedHierarchy_IndentsCorrectly()
    {
        var root = new InspectElementInfo
        {
            ControlType = "Window",
            Name = "Zoom Workplace"
        };
        var child = new InspectElementInfo
        {
            ControlType = "Pane",
            Name = "MainContent"
        };
        var button = new InspectElementInfo
        {
            ControlType = "Button",
            Name = "New Meeting"
        };

        root.Children.Add(child);
        child.Children.Add(button);

        var output = ElementFormatter.FormatTree(root);

        Assert.Contains("[Window]", output);
        Assert.Contains("[Pane]", output);
        Assert.Contains("[Button]", output);
        Assert.Contains("Name: New Meeting", output);
    }
}
