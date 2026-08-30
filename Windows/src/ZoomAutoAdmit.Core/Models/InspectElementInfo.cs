namespace ZoomAutoAdmit.Core.Models;

public class InspectElementInfo
{
    public string ControlType { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string AutomationId { get; set; } = string.Empty;
    public string ClassName { get; set; } = string.Empty;
    public string FrameworkType { get; set; } = string.Empty;
    public string? HelpText { get; set; }
    public string? Value { get; set; }
    public string? LegacyName { get; set; }
    public string? LegacyDescription { get; set; }
    public string? LegacyValue { get; set; }
    public string? LegacyState { get; set; }
    public string? LegacyDefaultAction { get; set; }
    public bool? IsSelected { get; set; }
    public string? ToggleState { get; set; }
    public bool? IsEnabled { get; set; }
    public bool? IsOffscreen { get; set; }
    public BoundingRectangleInfo? BoundingRectangle { get; set; }
    public int ProcessId { get; set; }
    public IntPtr NativeWindowHandle { get; set; }
    public int Depth { get; set; }
    public PatternSupportInfo Patterns { get; set; } = new();
    public List<InspectElementInfo> Children { get; } = new();
    public string? DiagnosticError { get; set; }
}
