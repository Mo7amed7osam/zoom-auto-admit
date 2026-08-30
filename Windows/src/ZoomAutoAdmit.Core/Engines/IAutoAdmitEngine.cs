using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Engines;

public interface IAutoAdmitEngine
{
    string Name { get; }
    Task<int> RunAsync(CliOptions options, CancellationToken cancellationToken = default);
}
