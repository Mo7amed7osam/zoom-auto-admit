using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.UIAutomation.Discovery;
using ZoomAutoAdmit.UIAutomation.Window;

namespace ZoomAutoAdmit.WindowsRuntime;

public sealed class WindowsDesktopMeetingPlatform : IWindowsDesktopMeetingPlatform
{
    private static readonly TimeSpan JoinTimeout = TimeSpan.FromSeconds(30);

    public Task<MeetingOperationResult> SwitchAccountAsync(
        MeetingAccount account,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        MeetingOperationResult result = MeetingOperationResult.Failure(
            $"Zoom account '{account.DisplayName}' was not found in the Desktop account menu.");
        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var automation = new UIA3Automation();
            var candidate = new ZoomProcessDiscovery().FindPrimaryCandidate();
            if (candidate == null)
            {
                result = MeetingOperationResult.Failure("Zoom Desktop is not running.");
                return;
            }

            var roots = candidate.Windows
                .Where(window => window.IsVisible)
                .Select(window => window.Handle)
                .Append(candidate.MainWindowHandle)
                .Where(handle => handle != IntPtr.Zero)
                .Distinct()
                .ToArray();
            AutomationElement? profileButton = null;
            foreach (var handle in roots)
            {
                try
                {
                    var root = automation.FromHandle(handle);
                    profileButton = FindProfileButton(root, candidate.ProcessId);
                    if (profileButton != null) break;
                }
                catch { }
            }
            if (profileButton == null) return;
            string currentName = profileButton.Properties.Name.ValueOrDefault ?? string.Empty;
            if (MatchesAccount(currentName, account))
            {
                result = MeetingOperationResult.Success();
                return;
            }
            if (!Invoke(profileButton))
            {
                result = MeetingOperationResult.Failure("The Zoom Desktop profile menu could not be opened.");
                return;
            }

            Thread.Sleep(400);
            foreach (var root in automation.GetDesktop().FindAllChildren())
            {
                var target = FindAccountEntry(root, candidate.ProcessId, account);
                if (target == null || !Invoke(target)) continue;
                result = MeetingOperationResult.Success();
                return;
            }
        });
        return Task.FromResult(result);
    }

    public Task<MeetingOperationResult> LaunchMeetingAsync(
        Uri meetingUrl,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            string protocolUrl = CreateZoomDesktopProtocolUrl(meetingUrl);
            Process.Start(new ProcessStartInfo(protocolUrl) { UseShellExecute = true });
            return Task.FromResult(MeetingOperationResult.Success());
        }
        catch (Exception ex)
        {
            return Task.FromResult(MeetingOperationResult.Failure(ex.Message));
        }
    }

    public async Task<MeetingOperationResult> VerifyJoinedAsync(CancellationToken cancellationToken)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + JoinTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (ZoomWindowManager.FindMainZoomMeetingWindow() != IntPtr.Zero)
                return MeetingOperationResult.Success();
            await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken);
        }
        return MeetingOperationResult.Failure("Zoom Desktop meeting window was not detected within 30 seconds.");
    }

    public Task<MeetingOperationResult> DisableMicrophoneAsync(CancellationToken cancellationToken) =>
        SetMeetingControlOffAsync("Mute", "Unmute", "microphone", cancellationToken);

    public Task<MeetingOperationResult> DisableCameraAsync(CancellationToken cancellationToken) =>
        SetMeetingControlOffAsync("Stop Video", "Start Video", "camera", cancellationToken);

    public Task<MeetingOperationResult> StopAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Stopping orchestration intentionally does not end the user's Zoom meeting.
        return Task.FromResult(MeetingOperationResult.Success());
    }

    internal static string CreateZoomDesktopProtocolUrl(Uri meetingUrl)
    {
        string[] segments = meetingUrl.AbsolutePath
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        string? meetingId = segments
            .FirstOrDefault(segment => segment.All(char.IsDigit) && segment.Length >= 9);
        if (meetingId == null)
            throw new ArgumentException("The Zoom meeting URL does not contain a valid meeting ID.", nameof(meetingUrl));
        string password = meetingUrl.Query
            .TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2))
            .Where(part => part.Length == 2 && part[0].Equals("pwd", StringComparison.OrdinalIgnoreCase))
            .Select(part => Uri.UnescapeDataString(part[1]))
            .FirstOrDefault() ?? string.Empty;
        string passwordPart = string.IsNullOrWhiteSpace(password)
            ? string.Empty
            : $"&pwd={Uri.EscapeDataString(password)}";
        return $"zoommtg://zoom.us/join?action=join&confno={meetingId}{passwordPart}";
    }

    private static Task<MeetingOperationResult> SetMeetingControlOffAsync(
        string turnOffName,
        string alreadyOffName,
        string controlLabel,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        MeetingOperationResult result = MeetingOperationResult.Failure(
            $"Zoom Desktop {controlLabel} control was not found.");
        DesktopThread.RunOnInteractiveDesktop(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            IntPtr meetingWindow = ZoomWindowManager.FindMainZoomMeetingWindow();
            if (meetingWindow == IntPtr.Zero) return;
            using var automation = new UIA3Automation();
            var root = automation.FromHandle(meetingWindow);
            if (FindExactNamedElement(root, alreadyOffName) != null)
            {
                result = MeetingOperationResult.Success();
                return;
            }
            var turnOff = FindExactNamedElement(root, turnOffName);
            if (turnOff != null && Invoke(turnOff)) result = MeetingOperationResult.Success();
        });
        return Task.FromResult(result);
    }

    private static AutomationElement? FindProfileButton(AutomationElement element, int processId)
    {
        try
        {
            if (element.Properties.ProcessId.ValueOrDefault != processId) return null;
            string controlType = element.Properties.ControlType.ValueOrDefault.ToString();
            string name = element.Properties.Name.ValueOrDefault ?? string.Empty;
            bool enabled = element.Properties.IsEnabled.ValueOrDefault;
            if (ProfileButtonMatcher.IsProfileSplitButton(
                    controlType,
                    name,
                    enabled,
                    element.Patterns.Invoke.IsSupported))
                return element;
            foreach (var child in element.FindAllChildren())
            {
                var match = FindProfileButton(child, processId);
                if (match != null) return match;
            }
        }
        catch { }
        return null;
    }

    private static AutomationElement? FindAccountEntry(
        AutomationElement element,
        int processId,
        MeetingAccount account)
    {
        try
        {
            if (element.Properties.ProcessId.ValueOrDefault != processId) return null;
            string name = element.Properties.Name.ValueOrDefault ?? string.Empty;
            if (MatchesAccount(name, account) &&
                (element.Patterns.Invoke.IsSupported ||
                 element.Patterns.SelectionItem.IsSupported ||
                 element.Patterns.LegacyIAccessible.IsSupported))
                return element;
            foreach (var child in element.FindAllChildren())
            {
                var match = FindAccountEntry(child, processId, account);
                if (match != null) return match;
            }
        }
        catch { }
        return null;
    }

    private static AutomationElement? FindExactNamedElement(AutomationElement element, string name)
    {
        try
        {
            string candidate = element.Properties.Name.ValueOrDefault ?? string.Empty;
            if (candidate.Trim().Equals(name, StringComparison.OrdinalIgnoreCase)) return element;
            foreach (var child in element.FindAllChildren())
            {
                var match = FindExactNamedElement(child, name);
                if (match != null) return match;
            }
        }
        catch { }
        return null;
    }

    private static bool MatchesAccount(string value, MeetingAccount account) =>
        value.Contains(account.DisplayName, StringComparison.OrdinalIgnoreCase) ||
        value.Contains(account.AccountId, StringComparison.OrdinalIgnoreCase);

    private static bool Invoke(AutomationElement element)
    {
        try
        {
            if (element.Patterns.Invoke.IsSupported)
            {
                element.Patterns.Invoke.Pattern.Invoke();
                return true;
            }
            if (element.Patterns.SelectionItem.IsSupported)
            {
                element.Patterns.SelectionItem.Pattern.Select();
                return true;
            }
            if (element.Patterns.LegacyIAccessible.IsSupported)
            {
                element.Patterns.LegacyIAccessible.Pattern.DoDefaultAction();
                return true;
            }
        }
        catch { }
        return false;
    }
}
