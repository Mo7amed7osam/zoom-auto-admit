using ZoomAutoAdmit.Core.Engines;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.Inspector.Commands;

namespace ZoomAutoAdmit.Inspector.Engines;

public sealed class WindowsAutoAdmitEngine : IAutoAdmitEngine
{
    public string Name => "windows";

    public Task<int> RunAsync(CliOptions options, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(WaitingRoomAutoAdmitCommand.Execute(options, cancellationToken));
    }
}
