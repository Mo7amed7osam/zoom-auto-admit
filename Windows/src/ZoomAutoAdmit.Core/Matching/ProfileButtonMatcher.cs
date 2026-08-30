using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public static class ProfileButtonMatcher
{
    public static bool IsProfileSplitButton(string? controlType, string? name, bool isEnabled, bool hasInvokePattern)
    {
        if (string.IsNullOrWhiteSpace(controlType) || string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        if (!controlType.Equals("SplitButton", StringComparison.OrdinalIgnoreCase) &&
            !controlType.Equals("Button", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (!isEnabled || !hasInvokePattern)
        {
            return false;
        }

        // Expected Zoom profile button formats:
        // "Zoom, <displayName>, Status, <Status>, <License> account"
        // or starts with "Zoom, " and contains "Status"
        if (name.StartsWith("Zoom,", StringComparison.OrdinalIgnoreCase) &&
            name.IndexOf("Status", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return true;
        }

        return false;
    }

    public static bool TryExtractDisplayName(string? name, out string displayName)
    {
        displayName = string.Empty;
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        var parts = name.Split(',');
        if (parts.Length >= 2 && parts[0].Trim().Equals("Zoom", StringComparison.OrdinalIgnoreCase))
        {
            displayName = parts[1].Trim();
            return !string.IsNullOrWhiteSpace(displayName);
        }

        return false;
    }
}
