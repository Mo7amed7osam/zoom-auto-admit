using System.Text;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Formatting;

public static class ElementFormatter
{
    public static string FormatSingleElement(InspectElementInfo element, int indentSpaces = 0)
    {
        var indent = new string(' ', indentSpaces);
        var subIndent = new string(' ', indentSpaces + 2);
        var sb = new StringBuilder();

        var controlType = string.IsNullOrWhiteSpace(element.ControlType) ? "Unknown" : element.ControlType;
        sb.AppendLine($"{indent}[{controlType}]");
        sb.AppendLine($"{subIndent}Name: {FormatValue(element.Name)}");
        sb.AppendLine($"{subIndent}AutomationId: {FormatValue(element.AutomationId)}");
        sb.AppendLine($"{subIndent}ClassName: {FormatValue(element.ClassName)}");
        if (!string.IsNullOrWhiteSpace(element.FrameworkType))
        {
            sb.AppendLine($"{subIndent}FrameworkType: {element.FrameworkType}");
        }
        if (!string.IsNullOrWhiteSpace(element.HelpText))
        {
            sb.AppendLine($"{subIndent}HelpText: {element.HelpText}");
        }
        if (!string.IsNullOrWhiteSpace(element.Value))
        {
            sb.AppendLine($"{subIndent}Value: {element.Value}");
        }
        if (!string.IsNullOrWhiteSpace(element.LegacyName) && !element.LegacyName.Equals(element.Name, StringComparison.Ordinal))
        {
            sb.AppendLine($"{subIndent}LegacyName: {element.LegacyName}");
        }
        if (!string.IsNullOrWhiteSpace(element.LegacyDescription))
        {
            sb.AppendLine($"{subIndent}LegacyDescription: {element.LegacyDescription}");
        }
        if (!string.IsNullOrWhiteSpace(element.LegacyValue))
        {
            sb.AppendLine($"{subIndent}LegacyValue: {element.LegacyValue}");
        }
        if (!string.IsNullOrWhiteSpace(element.LegacyState))
        {
            sb.AppendLine($"{subIndent}LegacyState: {element.LegacyState}");
        }
        if (!string.IsNullOrWhiteSpace(element.LegacyDefaultAction))
        {
            sb.AppendLine($"{subIndent}LegacyDefaultAction: {element.LegacyDefaultAction}");
        }
        if (element.IsSelected.HasValue)
        {
            sb.AppendLine($"{subIndent}IsSelected: {element.IsSelected.Value}");
        }
        if (!string.IsNullOrWhiteSpace(element.ToggleState))
        {
            sb.AppendLine($"{subIndent}ToggleState: {element.ToggleState}");
        }
        sb.AppendLine($"{subIndent}Enabled: {(element.IsEnabled.HasValue ? element.IsEnabled.Value.ToString() : "unknown")}");
        sb.AppendLine($"{subIndent}Offscreen: {(element.IsOffscreen.HasValue ? element.IsOffscreen.Value.ToString() : "unknown")}");

        if (element.BoundingRectangle != null)
        {
            sb.AppendLine($"{subIndent}BoundingRectangle: {element.BoundingRectangle}");
        }

        if (element.ProcessId > 0)
        {
            sb.AppendLine($"{subIndent}ProcessId: {element.ProcessId}");
        }

        if (element.NativeWindowHandle != IntPtr.Zero)
        {
            sb.AppendLine($"{subIndent}NativeWindowHandle: 0x{element.NativeWindowHandle.ToInt64():X}");
        }

        var patterns = element.Patterns.GetSupportedPatternNames();
        if (patterns.Count > 0)
        {
            sb.AppendLine($"{subIndent}Patterns:");
            foreach (var p in patterns)
            {
                sb.AppendLine($"{subIndent}  {p}: yes");
            }
        }
        else
        {
            sb.AppendLine($"{subIndent}Patterns: (none detected)");
        }

        if (!string.IsNullOrWhiteSpace(element.DiagnosticError))
        {
            sb.AppendLine($"{subIndent}DiagnosticWarning: {element.DiagnosticError}");
        }

        return sb.ToString().TrimEnd();
    }

    public static string FormatTree(InspectElementInfo root, int currentDepth = 0)
    {
        var sb = new StringBuilder();
        sb.AppendLine(FormatSingleElement(root, currentDepth * 2));

        foreach (var child in root.Children)
        {
            sb.AppendLine();
            sb.Append(FormatTree(child, currentDepth + 1));
        }

        return sb.ToString().TrimEnd();
    }

    private static string FormatValue(string? val)
    {
        if (string.IsNullOrEmpty(val)) return "(empty)";
        if (string.IsNullOrWhiteSpace(val)) return $"(whitespace, length {val.Length})";
        return val;
    }
}
