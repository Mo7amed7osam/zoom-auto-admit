using ZoomAutoAdmit.Core.Engines;
using ZoomAutoAdmit.WebAutomation;

namespace ZoomAutoAdmit.Inspector.Engines;

public static class AutoAdmitEngineFactory
{
    public static IAutoAdmitEngine Create(string engine) => engine.ToLowerInvariant() switch
    {
        "windows" => new WindowsAutoAdmitEngine(),
        "web" => new WebAutoAdmitEngine(),
        _ => throw new ArgumentException(
            $"Unknown auto-admit engine '{engine}'. Expected 'windows' or 'web'.",
            nameof(engine))
    };
}
