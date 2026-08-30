using ZoomAutoAdmit.Core.Filtering;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

/// <summary>
/// UNIT TESTED: Tests for ElementFilter search matching logic.
/// </summary>
public class ElementFilterTests
{
    [Theory]
    [InlineData("Admit", "Admit", true)]
    [InlineData("admit", "Admit All", true)]
    [InlineData("ADMIT", "admit_button", true)]
    [InlineData("Participants", "ParticipantsList", true)]
    [InlineData("NonExistent", "Zoom Meeting", false)]
    public void Matches_ByName_MatchesCaseInsensitively(string query, string name, bool expected)
    {
        var element = new InspectElementInfo
        {
            Name = name,
            AutomationId = "other_id",
            ClassName = "other_class"
        };

        var result = ElementFilter.Matches(element, query);
        Assert.Equal(expected, result);
    }

    [Fact]
    public void Matches_ByAutomationIdOrClassName_ReturnsTrue()
    {
        var element = new InspectElementInfo
        {
            Name = "Click Me",
            AutomationId = "btn_admit_all",
            ClassName = "ZPButtonCustom"
        };

        Assert.True(ElementFilter.Matches(element, "admit_all"));
        Assert.True(ElementFilter.Matches(element, "zpbutton"));
    }

    [Fact]
    public void FindMatches_TraversesHierarchyAndFindsMatches()
    {
        var root = new InspectElementInfo { Name = "Root Window" };
        var child1 = new InspectElementInfo { Name = "Header Pane" };
        var child2 = new InspectElementInfo { Name = "Waiting Room Section" };
        var admitBtn = new InspectElementInfo { Name = "Admit", AutomationId = "btn_admit" };
        var admitAllBtn = new InspectElementInfo { Name = "Admit All", AutomationId = "btn_admit_all" };

        root.Children.Add(child1);
        root.Children.Add(child2);
        child2.Children.Add(admitBtn);
        child2.Children.Add(admitAllBtn);

        var matches = ElementFilter.FindMatches(root, "admit");

        Assert.Equal(2, matches.Count);
        Assert.Contains(matches, m => m.Name == "Admit");
        Assert.Contains(matches, m => m.Name == "Admit All");
    }

    [Fact]
    public void Matches_EmptyQuery_ReturnsTrue()
    {
        var element = new InspectElementInfo { Name = "Anything" };
        Assert.True(ElementFilter.Matches(element, ""));
        Assert.True(ElementFilter.Matches(element, "   "));
        Assert.True(ElementFilter.Matches(element, null));
    }
}
