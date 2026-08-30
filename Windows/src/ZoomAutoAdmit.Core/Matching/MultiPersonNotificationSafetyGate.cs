using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

public enum MultiPersonNotificationDecisionKind
{
    Rejected,
    FirstFrameAccepted,
    Armed,
    ClickReady
}

public sealed record MultiPersonNotificationDecision(
    MultiPersonNotificationDecisionKind Kind,
    string Reason,
    MultiPersonWaitingNotificationCandidate? Candidate = null);

public sealed class MultiPersonNotificationSafetyGate
{
    private Snapshot? _first;
    private Snapshot? _armed;
    private bool _clickSent;

    public MultiPersonNotificationDecision Observe(
        MultiPersonWaitingNotificationCandidate candidate,
        BoundingRectangleInfo primaryBounds,
        DateTimeOffset captureCompletedAt)
    {
        if (!IsSafe(candidate, primaryBounds, out string reason))
            return new(MultiPersonNotificationDecisionKind.Rejected, reason);

        var current = Snapshot.From(candidate, captureCompletedAt);
        if (_first == null)
        {
            _first = current;
            return new(MultiPersonNotificationDecisionKind.FirstFrameAccepted, "First multi-person frame accepted.", candidate);
        }
        if (captureCompletedAt - _first.CapturedAt > AdmitOnceSafetyGate.MaximumConfirmationGap ||
            !Matches(_first, current))
        {
            _first = current;
            _armed = null;
            return new(MultiPersonNotificationDecisionKind.Rejected, "Multi-person confirmation frame is stale or changed.");
        }
        _armed = current;
        return new(MultiPersonNotificationDecisionKind.Armed, "Two matching multi-person frames accepted.", candidate);
    }

    public MultiPersonNotificationDecision ValidateFinal(
        MultiPersonWaitingNotificationCandidate candidate,
        BoundingRectangleInfo primaryBounds,
        DateTimeOffset captureCompletedAt,
        bool interactiveDesktop)
    {
        if (_clickSent || _armed == null || !interactiveDesktop)
            return new(MultiPersonNotificationDecisionKind.Rejected, "View action is not armed on the Default input desktop.");
        if (captureCompletedAt - _armed.CapturedAt > AdmitOnceSafetyGate.MaximumFinalFrameGap)
            return new(MultiPersonNotificationDecisionKind.Rejected, "Final multi-person frame is stale.");
        if (!IsSafe(candidate, primaryBounds, out string reason))
            return new(MultiPersonNotificationDecisionKind.Rejected, reason);
        var current = Snapshot.From(candidate, captureCompletedAt);
        if (!Matches(_armed, current))
            return new(MultiPersonNotificationDecisionKind.Rejected, "Final View target no longer matches the armed notification.");
        return new(MultiPersonNotificationDecisionKind.ClickReady, "Final fresh View target confirmed.", candidate);
    }

    public bool TryMarkClickSent()
    {
        if (_clickSent) return false;
        _clickSent = true;
        return true;
    }

    private static bool IsSafe(
        MultiPersonWaitingNotificationCandidate candidate,
        BoundingRectangleInfo primary,
        out string reason)
    {
        if (!candidate.IsAccepted || candidate.Confidence < AdmitOnceSafetyGate.HighConfidence ||
            candidate.WaitingCount < 2 || candidate.ViewWord == null ||
            !candidate.ViewWord.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase))
        {
            reason = "Multi-person notification is incomplete or below the 95% action threshold.";
            return false;
        }
        if (!Contains(primary, candidate.ViewCenter) || !Contains(candidate.NotificationBounds, candidate.ViewCenter))
        {
            reason = "Dynamic View center is outside Primary Screen or notification bounds.";
            return false;
        }
        reason = string.Empty;
        return true;
    }

    private static bool Matches(Snapshot first, Snapshot second) =>
        first.Count == second.Count &&
        Distance(first.ViewCenter, second.ViewCenter) <= AdmitOnceSafetyGate.CenterMovementTolerance &&
        IntersectionOverUnion(first.Bounds, second.Bounds) >= AdmitOnceSafetyGate.MinimumToastOverlap;

    private static bool Contains(BoundingRectangleInfo bounds, (double X, double Y) point) =>
        point.X >= bounds.X && point.X <= bounds.X + bounds.Width &&
        point.Y >= bounds.Y && point.Y <= bounds.Y + bounds.Height;
    private static double Distance((double X, double Y) first, (double X, double Y) second) =>
        Math.Sqrt(Math.Pow(first.X - second.X, 2) + Math.Pow(first.Y - second.Y, 2));
    private static double IntersectionOverUnion(BoundingRectangleInfo first, BoundingRectangleInfo second)
    {
        double left = Math.Max(first.X, second.X);
        double top = Math.Max(first.Y, second.Y);
        double right = Math.Min(first.X + first.Width, second.X + second.Width);
        double bottom = Math.Min(first.Y + first.Height, second.Y + second.Height);
        double intersection = Math.Max(0, right - left) * Math.Max(0, bottom - top);
        double union = first.Width * first.Height + second.Width * second.Height - intersection;
        return union <= 0 ? 0 : intersection / union;
    }

    private sealed record Snapshot(
        int Count,
        BoundingRectangleInfo Bounds,
        (double X, double Y) ViewCenter,
        DateTimeOffset CapturedAt)
    {
        public static Snapshot From(MultiPersonWaitingNotificationCandidate candidate, DateTimeOffset capturedAt) =>
            new(candidate.WaitingCount, candidate.NotificationBounds, candidate.ViewCenter, capturedAt);
    }
}
