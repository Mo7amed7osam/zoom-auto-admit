using FlaUI.Core.AutomationElements;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.UIAutomation.Inspection;

public static class FlaUiElementExtractor
{
    public static InspectElementInfo ExtractElementInfo(AutomationElement element, int currentDepth)
    {
        var info = new InspectElementInfo
        {
            Depth = currentDepth
        };

        try
        {
            info.ControlType = TryGet(() => element.Properties.ControlType.Value.ToString(), "Unknown");
            info.Name = TryGet(() => element.Properties.Name.Value, string.Empty);
            info.AutomationId = TryGet(() => element.Properties.AutomationId.Value, string.Empty);
            info.ClassName = TryGet(() => element.Properties.ClassName.Value, string.Empty);
            info.FrameworkType = TryGet(() => element.Properties.FrameworkId.Value, string.Empty);
            info.HelpText = TryGetNullable(() => element.Properties.HelpText.ValueOrDefault);
            info.IsEnabled = TryGetNullable(() => (bool?)element.Properties.IsEnabled.Value);
            info.IsOffscreen = TryGetNullable(() => (bool?)element.Properties.IsOffscreen.Value);
            info.ProcessId = TryGet(() => element.Properties.ProcessId.Value, 0);
            info.NativeWindowHandle = TryGet(() => element.Properties.NativeWindowHandle.Value, IntPtr.Zero);

            if (element.Patterns.Value.IsSupported)
            {
                info.Value = TryGetNullable(() => element.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault);
            }

            if (element.Patterns.LegacyIAccessible.IsSupported)
            {
                var legacy = element.Patterns.LegacyIAccessible.PatternOrDefault;
                if (legacy != null)
                {
                    info.LegacyName = TryGetNullable(() => legacy.Name.ValueOrDefault);
                    info.LegacyDescription = TryGetNullable(() => legacy.Description.ValueOrDefault);
                    info.LegacyValue = TryGetNullable(() => legacy.Value.ValueOrDefault);
                    info.LegacyState = TryGetNullable(() => legacy.State.ValueOrDefault.ToString());
                    info.LegacyDefaultAction = TryGetNullable(() => legacy.DefaultAction.ValueOrDefault);
                }
            }

            if (element.Patterns.SelectionItem.IsSupported)
            {
                info.IsSelected = TryGetNullable(() => (bool?)element.Patterns.SelectionItem.PatternOrDefault?.IsSelected.ValueOrDefault);
            }

            if (element.Patterns.Toggle.IsSupported)
            {
                info.ToggleState = TryGetNullable(() => element.Patterns.Toggle.PatternOrDefault?.ToggleState.ValueOrDefault.ToString());
            }

            var bounds = TryGetNullable(() =>
            {
                var r = element.Properties.BoundingRectangle.Value;
                return new BoundingRectangleInfo(r.X, r.Y, r.Width, r.Height);
            });
            info.BoundingRectangle = bounds;

            info.Patterns = ExtractPatternSupport(element);
        }
        catch (Exception ex)
        {
            info.DiagnosticError = $"Failed to read element attributes: {ex.Message}";
        }

        return info;
    }

    public static PatternSupportInfo ExtractPatternSupport(AutomationElement element)
    {
        return new PatternSupportInfo
        {
            HasInvoke = IsPatternSupported(() => element.Patterns.Invoke.IsSupported),
            HasSelectionItem = IsPatternSupported(() => element.Patterns.SelectionItem.IsSupported),
            HasSelection = IsPatternSupported(() => element.Patterns.Selection.IsSupported),
            HasExpandCollapse = IsPatternSupported(() => element.Patterns.ExpandCollapse.IsSupported),
            HasToggle = IsPatternSupported(() => element.Patterns.Toggle.IsSupported),
            HasValue = IsPatternSupported(() => element.Patterns.Value.IsSupported),
            HasLegacyIAccessible = IsPatternSupported(() => element.Patterns.LegacyIAccessible.IsSupported),
            HasWindow = IsPatternSupported(() => element.Patterns.Window.IsSupported),
            HasTransform = IsPatternSupported(() => element.Patterns.Transform.IsSupported),
            HasScroll = IsPatternSupported(() => element.Patterns.Scroll.IsSupported),
            HasGrid = IsPatternSupported(() => element.Patterns.Grid.IsSupported),
            HasGridItem = IsPatternSupported(() => element.Patterns.GridItem.IsSupported),
            HasTable = IsPatternSupported(() => element.Patterns.Table.IsSupported),
            HasTableItem = IsPatternSupported(() => element.Patterns.TableItem.IsSupported),
            HasText = IsPatternSupported(() => element.Patterns.Text.IsSupported)
        };
    }

    private static bool IsPatternSupported(Func<bool> checkFunc)
    {
        try
        {
            return checkFunc();
        }
        catch
        {
            return false;
        }
    }

    private static T TryGet<T>(Func<T> getter, T defaultValue)
    {
        try
        {
            var value = getter();
            return value ?? defaultValue;
        }
        catch
        {
            return defaultValue;
        }
    }

    private static T? TryGetNullable<T>(Func<T?> getter) where T : struct
    {
        try
        {
            return getter();
        }
        catch
        {
            return null;
        }
    }

    private static T? TryGetNullable<T>(Func<T?> getter) where T : class
    {
        try
        {
            return getter();
        }
        catch
        {
            return null;
        }
    }
}
