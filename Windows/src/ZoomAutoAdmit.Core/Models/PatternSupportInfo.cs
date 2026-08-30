namespace ZoomAutoAdmit.Core.Models;

public record PatternSupportInfo
{
    public bool HasInvoke { get; init; }
    public bool HasSelectionItem { get; init; }
    public bool HasSelection { get; init; }
    public bool HasExpandCollapse { get; init; }
    public bool HasToggle { get; init; }
    public bool HasValue { get; init; }
    public bool HasLegacyIAccessible { get; init; }
    public bool HasWindow { get; init; }
    public bool HasTransform { get; init; }
    public bool HasScroll { get; init; }
    public bool HasGrid { get; init; }
    public bool HasGridItem { get; init; }
    public bool HasTable { get; init; }
    public bool HasTableItem { get; init; }
    public bool HasText { get; init; }

    public IReadOnlyList<string> GetSupportedPatternNames()
    {
        var list = new List<string>();
        if (HasInvoke) list.Add("InvokePattern");
        if (HasSelectionItem) list.Add("SelectionItemPattern");
        if (HasSelection) list.Add("SelectionPattern");
        if (HasExpandCollapse) list.Add("ExpandCollapsePattern");
        if (HasToggle) list.Add("TogglePattern");
        if (HasValue) list.Add("ValuePattern");
        if (HasLegacyIAccessible) list.Add("LegacyIAccessiblePattern");
        if (HasWindow) list.Add("WindowPattern");
        if (HasTransform) list.Add("TransformPattern");
        if (HasScroll) list.Add("ScrollPattern");
        if (HasGrid) list.Add("GridPattern");
        if (HasGridItem) list.Add("GridItemPattern");
        if (HasTable) list.Add("TablePattern");
        if (HasTableItem) list.Add("TableItemPattern");
        if (HasText) list.Add("TextPattern");
        return list;
    }
}
