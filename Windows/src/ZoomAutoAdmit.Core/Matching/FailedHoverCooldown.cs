using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public sealed class FailedHoverCooldown
{
    private readonly TimeSpan _duration;
    private readonly List<Entry> _entries = new();

    public FailedHoverCooldown(TimeSpan? duration = null) =>
        _duration = duration ?? TimeSpan.FromMilliseconds(1500);

    public void MarkFailed(WaitingParticipantRowCandidate row, DateTimeOffset now)
    {
        Prune(now);
        _entries.RemoveAll(entry => SameRow(entry, row));
        _entries.Add(new Entry(row.ParticipantName.Trim(), Center(row.RowBounds), now));
    }

    public bool IsCoolingDown(WaitingParticipantRowCandidate row, DateTimeOffset now)
    {
        Prune(now);
        return _entries.Any(entry => SameRow(entry, row));
    }

    private void Prune(DateTimeOffset now) => _entries.RemoveAll(entry => now - entry.FailedAt >= _duration);
    private static bool SameRow(Entry entry, WaitingParticipantRowCandidate row) =>
        entry.Participant.Equals(row.ParticipantName.Trim(), StringComparison.OrdinalIgnoreCase) &&
        Distance(entry.Center, Center(row.RowBounds)) <= 8;
    private static (double X, double Y) Center(BoundingRectangleInfo bounds) =>
        (bounds.X + bounds.Width / 2.0, bounds.Y + bounds.Height / 2.0);
    private static double Distance((double X, double Y) first, (double X, double Y) second) =>
        Math.Sqrt(Math.Pow(first.X - second.X, 2) + Math.Pow(first.Y - second.Y, 2));
    private sealed record Entry(string Participant, (double X, double Y) Center, DateTimeOffset FailedAt);
}
