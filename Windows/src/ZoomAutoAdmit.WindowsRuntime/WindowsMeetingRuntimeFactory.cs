using ZoomAutoAdmit.Core.Meetings;
using ZoomAutoAdmit.Core.Sessions;

namespace ZoomAutoAdmit.WindowsRuntime;

public sealed class WindowsMeetingRuntimeFactory(
    WindowsDesktopMeetingLauncher desktop,
    WindowsWebMeetingLauncher web) : IMeetingEngineRuntimeFactory
{
    public IMeetingEngineRuntime Get(SessionEngineType engineType) => engineType switch
    {
        SessionEngineType.Desktop => desktop,
        SessionEngineType.Web => web,
        _ => throw new ArgumentOutOfRangeException(nameof(engineType), engineType, null)
    };
}
