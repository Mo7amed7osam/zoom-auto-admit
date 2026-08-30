using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public sealed class ViewPanelTransitionVerifier
{
    public bool IsVerified(ParticipantsPanelDetectionResult panel) =>
        panel.IsPanelVisible && panel.ParticipantsHeader != null && panel.WaitingRoomHeader != null;
}

public sealed class BatchAdmissionVerifier
{
    private readonly HashSet<string> _originalParticipants;
    private readonly BoundingRectangleInfo _participantsHeaderBounds;
    private int _consecutiveSuccesses;

    public BatchAdmissionVerifier(PanelAdmitAllCandidate original)
    {
        _originalParticipants = original.OriginalParticipants
            .Select(Normalize)
            .Where(name => name.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        _participantsHeaderBounds = original.Panel.ParticipantsHeader?.Bounds ?? BoundingRectangleInfo.Empty;
    }

    public BatchAdmissionVerificationResult Observe(ParticipantsPanelDetectionResult current)
    {
        bool samePanelWithoutWaiting = current.ParticipantsHeader != null &&
                                       current.WaitingRoomHeader == null &&
                                       SameHeaderNeighborhood(current.ParticipantsHeader.Bounds, _participantsHeaderBounds);
        var currentNames = current.Rows.Select(row => Normalize(row.ParticipantName)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        bool originalSetGone = _originalParticipants.Count > 0 && _originalParticipants.All(name => !currentNames.Contains(name));
        bool countZero = current.IsPanelVisible && current.DeclaredWaitingCount == 0;
        bool success = samePanelWithoutWaiting || countZero || (current.IsPanelVisible && originalSetGone);
        _consecutiveSuccesses = success ? _consecutiveSuccesses + 1 : 0;

        return _consecutiveSuccesses >= 2
            ? new(BatchAdmissionVerificationKind.Verified, "All original Waiting Room participants are absent in two consecutive captures.")
            : new(BatchAdmissionVerificationKind.Pending, success
                ? "One successful batch-verification frame observed."
                : "One or more original Waiting Room participants remain visible.");
    }

    private static string Normalize(string value) =>
        string.Join(" ", value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();
    private static bool SameHeaderNeighborhood(BoundingRectangleInfo current, BoundingRectangleInfo original)
    {
        if (current.Width <= 0 || current.Height <= 0 || original.Width <= 0 || original.Height <= 0) return false;
        double dx = Math.Abs((current.X + current.Width / 2.0) - (original.X + original.Width / 2.0));
        double dy = Math.Abs((current.Y + current.Height / 2.0) - (original.Y + original.Height / 2.0));
        return dx <= 40 && dy <= 30;
    }
}

public sealed class HandledBatchCache
{
    private readonly TimeSpan _ttl;
    private readonly List<Entry> _entries = new();

    public HandledBatchCache(TimeSpan? ttl = null) => _ttl = ttl ?? TimeSpan.FromSeconds(20);

    public bool IsSuppressed(PanelAdmitAllCandidate candidate, DateTimeOffset now)
    {
        Prune(now);
        string identity = Identity(candidate);
        var center = Center(candidate.Panel.PanelBounds);
        return _entries.Any(entry => entry.Identity.Equals(identity, StringComparison.OrdinalIgnoreCase) &&
                                     Distance(entry.PanelCenter, center) <= 100);
    }

    public void MarkHandled(PanelAdmitAllCandidate candidate, DateTimeOffset now)
    {
        Prune(now);
        _entries.Add(new Entry(Identity(candidate), Center(candidate.Panel.PanelBounds), now));
    }

    public void Forget(PanelAdmitAllCandidate candidate)
    {
        string identity = Identity(candidate);
        var center = Center(candidate.Panel.PanelBounds);
        _entries.RemoveAll(entry => entry.Identity.Equals(identity, StringComparison.OrdinalIgnoreCase) &&
                                    Distance(entry.PanelCenter, center) <= 100);
    }

    private void Prune(DateTimeOffset now) => _entries.RemoveAll(entry => now - entry.HandledAt >= _ttl);
    private static string Identity(PanelAdmitAllCandidate candidate)
    {
        var names = candidate.OriginalParticipants.OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToList();
        return names.Count > 0 ? string.Join("|", names) : $"count:{candidate.WaitingCount?.ToString() ?? "unknown"}";
    }
    private static (double X, double Y) Center(BoundingRectangleInfo bounds) =>
        (bounds.X + bounds.Width / 2.0, bounds.Y + bounds.Height / 2.0);
    private static double Distance((double X, double Y) first, (double X, double Y) second) =>
        Math.Sqrt(Math.Pow(first.X - second.X, 2) + Math.Pow(first.Y - second.Y, 2));
    private sealed record Entry(string Identity, (double X, double Y) PanelCenter, DateTimeOffset HandledAt);
}

public sealed class HandledMultiNotificationCache
{
    private readonly TimeSpan _ttl;
    private readonly List<Entry> _entries = new();
    public HandledMultiNotificationCache(TimeSpan? ttl = null) => _ttl = ttl ?? TimeSpan.FromSeconds(20);

    public bool IsSuppressed(MultiPersonWaitingNotificationCandidate candidate, DateTimeOffset now)
    {
        Prune(now);
        return _entries.Any(entry => entry.Count == candidate.WaitingCount &&
                                     Distance(entry.Center, Center(candidate.NotificationBounds)) <= 100);
    }

    public void MarkHandled(MultiPersonWaitingNotificationCandidate candidate, DateTimeOffset now)
    {
        Prune(now);
        _entries.Add(new Entry(candidate.WaitingCount, Center(candidate.NotificationBounds), now));
    }

    public void ObserveSuccessfulTransition(
        MultiPersonWaitingNotificationCandidate handled,
        IEnumerable<MultiPersonWaitingNotificationCandidate> currentCandidates)
    {
        bool originalStillVisible = currentCandidates.Any(candidate => candidate.IsAccepted &&
            candidate.WaitingCount == handled.WaitingCount &&
            Distance(Center(candidate.NotificationBounds), Center(handled.NotificationBounds)) <= 100);
        if (!originalStillVisible)
        {
            _entries.RemoveAll(entry => entry.Count == handled.WaitingCount &&
                                        Distance(entry.Center, Center(handled.NotificationBounds)) <= 100);
        }
    }

    private void Prune(DateTimeOffset now) => _entries.RemoveAll(entry => now - entry.HandledAt >= _ttl);
    private static (double X, double Y) Center(BoundingRectangleInfo bounds) =>
        (bounds.X + bounds.Width / 2.0, bounds.Y + bounds.Height / 2.0);
    private static double Distance((double X, double Y) first, (double X, double Y) second) =>
        Math.Sqrt(Math.Pow(first.X - second.X, 2) + Math.Pow(first.Y - second.Y, 2));
    private sealed record Entry(int Count, (double X, double Y) Center, DateTimeOffset HandledAt);
}
