using Microsoft.Playwright;

namespace ZoomAutoAdmit.WebAutomation;

internal static class PlaywrightNavigationFailurePolicy
{
    private static readonly string[] TransientMessages =
    [
        "frame was detached",
        "frame got detached",
        "execution context was destroyed",
        "cannot find context with specified id",
        "target page has been closed",
        "page was closed",
        "navigation interrupted"
    ];

    public static bool IsTransient(PlaywrightException exception) =>
        TransientMessages.Any(message =>
            exception.Message.Contains(message, StringComparison.OrdinalIgnoreCase));
}
