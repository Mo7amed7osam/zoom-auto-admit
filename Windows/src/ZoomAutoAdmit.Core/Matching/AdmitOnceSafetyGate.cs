using ZoomAutoAdmit.Core.Models;
using System.Text.RegularExpressions;

namespace ZoomAutoAdmit.Core.Matching;

public enum AdmitOnceDecisionKind
{
    Rejected,
    FirstFrameAccepted,
    Armed,
    ClickReady,
    DuplicateRejected,
    VerificationPending,
    Verified,
    VerificationTimedOut
}

public sealed record AdmitOnceDecision(
    AdmitOnceDecisionKind Kind,
    string Reason,
    WaitingRoomToastCandidate? Candidate = null);

/// <summary>
/// Pure safety state machine for a single dynamically localized Admit click.
/// It does not capture the screen or send mouse input.
/// </summary>
public sealed class AdmitOnceSafetyGate
{
    public const double HighConfidence = 0.95;
    public const double CenterMovementTolerance = 12.0;
    public const double MinimumToastOverlap = 0.60;
    // Timestamps passed to this gate are CaptureCompletedAt values, not OCR-start
    // or detection-completed values. Two seconds is bounded but accommodates the
    // proven PNG + WinRT OCR pipeline.
    public static readonly TimeSpan MaximumConfirmationGap = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan MaximumFinalFrameGap = TimeSpan.FromSeconds(2);

    private ToastSnapshot? _firstFrame;
    private ToastSnapshot? _armedFrame;
    private ToastSnapshot? _clickedToast;
    private bool _clickSent;

    public AdmitOnceDecision ObserveConfirmationFrame(
        IReadOnlyList<WaitingRoomToastCandidate> candidates,
        BoundingRectangleInfo primaryScreenBounds,
        DateTimeOffset timestamp)
    {
        if (_clickSent)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.DuplicateRejected, "A click has already been sent by this command.");
        }

        var selection = SelectSingleSafeCandidate(candidates, primaryScreenBounds);
        if (selection.Candidate == null)
        {
            _firstFrame = null;
            _armedFrame = null;
            return selection;
        }

        var current = ToastSnapshot.From(selection.Candidate, timestamp);
        if (_firstFrame == null)
        {
            _firstFrame = current;
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.FirstFrameAccepted,
                "First high-confidence frame accepted; a consecutive matching frame is required.",
                selection.Candidate);
        }

        if (timestamp - _firstFrame.Timestamp > MaximumConfirmationGap)
        {
            _firstFrame = current;
            _armedFrame = null;
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.Rejected,
                "The previous detection is stale; this frame becomes the new first frame.",
                selection.Candidate);
        }

        if (!Matches(_firstFrame, current, out var mismatchReason))
        {
            _firstFrame = current;
            _armedFrame = null;
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.Rejected,
                $"Consecutive-frame confirmation failed: {mismatchReason}",
                selection.Candidate);
        }

        _armedFrame = current;
        return new AdmitOnceDecision(
            AdmitOnceDecisionKind.Armed,
            "Two consecutive high-confidence frames identify the same stable toast.",
            selection.Candidate);
    }

    public AdmitOnceDecision ValidateFinalFrame(
        IReadOnlyList<WaitingRoomToastCandidate> candidates,
        BoundingRectangleInfo primaryScreenBounds,
        DateTimeOffset timestamp,
        bool interactiveDesktop)
    {
        if (_clickSent)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.DuplicateRejected, "A click has already been sent by this command.");
        }

        if (_armedFrame == null)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "The click is not armed by two matching frames.");
        }

        if (!interactiveDesktop)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "The input desktop is locked or unavailable.");
        }

        if (timestamp - _armedFrame.Timestamp > MaximumFinalFrameGap)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "The final captured frame is too far from the armed frame.");
        }

        var selection = SelectSingleSafeCandidate(candidates, primaryScreenBounds);
        if (selection.Candidate == null)
        {
            return selection;
        }

        var current = ToastSnapshot.From(selection.Candidate, timestamp);
        if (!Matches(_armedFrame, current, out var mismatchReason))
        {
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.Rejected,
                $"Final capture no longer matches the armed toast: {mismatchReason}",
                selection.Candidate);
        }

        var admit = selection.Candidate.AdmitWord!.Bounds;
        var center = selection.Candidate.AdmitCenter;
        if (!Contains(admit, center.X, center.Y))
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "Dynamic target is outside the current Admit rectangle.");
        }

        return new AdmitOnceDecision(
            AdmitOnceDecisionKind.ClickReady,
            "Final fresh capture confirms one stable target on the interactive primary screen.",
            selection.Candidate);
    }

    public bool TryMarkClickSent(WaitingRoomToastCandidate candidate, DateTimeOffset timestamp)
    {
        if (_clickSent)
        {
            return false;
        }

        _clickSent = true;
        _clickedToast = ToastSnapshot.From(candidate, timestamp);
        return true;
    }

    public AdmitOnceDecision ObserveVerificationFrame(
        IReadOnlyList<WaitingRoomToastCandidate> candidates,
        DateTimeOffset timestamp,
        DateTimeOffset deadline)
    {
        if (!_clickSent || _clickedToast == null)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "No click was sent.");
        }

        bool sameTargetStillVisible = candidates
            .Where(IsHighConfidenceCandidate)
            .Select(candidate => ToastSnapshot.From(candidate, timestamp))
            .Any(current => Matches(_clickedToast, current, out _));

        if (!sameTargetStillVisible)
        {
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.Verified,
                "The same Waiting Room Admit target disappeared after the click.");
        }

        if (timestamp >= deadline)
        {
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.VerificationTimedOut,
                "The same Admit target remained visible until the verification deadline.");
        }

        return new AdmitOnceDecision(
            AdmitOnceDecisionKind.VerificationPending,
            "The same Admit target is still visible.");
    }

    private static AdmitOnceDecision SelectSingleSafeCandidate(
        IReadOnlyList<WaitingRoomToastCandidate> candidates,
        BoundingRectangleInfo primaryScreenBounds)
    {
        var safeCandidates = candidates.Where(IsHighConfidenceCandidate).ToList();
        if (safeCandidates.Count == 0)
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "No high-confidence complete Waiting Room toast candidate.");
        }

        if (safeCandidates.Count != 1)
        {
            return new AdmitOnceDecision(
                AdmitOnceDecisionKind.Rejected,
                $"Conflicting candidates detected ({safeCandidates.Count}); exactly one is required.");
        }

        var candidate = safeCandidates[0];
        var center = candidate.AdmitCenter;
        if (!Contains(primaryScreenBounds, center.X, center.Y))
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "Admit center is outside Primary Screen bounds.");
        }

        if (!Contains(candidate.ToastBounds, center.X, center.Y))
        {
            return new AdmitOnceDecision(AdmitOnceDecisionKind.Rejected, "Admit center is outside the detected toast region.");
        }

        return new AdmitOnceDecision(AdmitOnceDecisionKind.FirstFrameAccepted, "Single safe candidate selected.", candidate);
    }

    private static bool IsHighConfidenceCandidate(WaitingRoomToastCandidate candidate) =>
        GetActionFilterRejectionReasons(candidate).Count == 0;

    public static IReadOnlyList<string> GetActionFilterRejectionReasons(WaitingRoomToastCandidate candidate)
    {
        var reasons = new List<string>();
        if (!candidate.IsAccepted) reasons.Add("WaitingRoomToastDetector did not accept the candidate.");
        if (candidate.Confidence < HighConfidence) reasons.Add($"Confidence {candidate.Confidence:P0} is below the 95% action threshold.");
        if (string.IsNullOrWhiteSpace(candidate.ParticipantName)) reasons.Add("Participant text is empty.");
        if (candidate.HeaderLine == null) reasons.Add("Waiting-room header is missing.");
        else if (!HasEnteredWaitingRoomRelation(candidate)) reasons.Add("Verified entered-the / waiting-room structural relation is missing.");
        if (candidate.AdmitWord == null || !candidate.AdmitWord.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase))
            reasons.Add("Exact Admit OCR word is missing.");
        if (candidate.ViewWord == null || !candidate.ViewWord.Text.Trim().Equals("View", StringComparison.OrdinalIgnoreCase))
            reasons.Add("Exact View OCR word is missing.");
        if (candidate.RejectionReasons.Count > 0) reasons.Add("Detector reported one or more candidate rejection reasons.");
        return reasons;
    }

    private static bool HasEnteredWaitingRoomRelation(WaitingRoomToastCandidate candidate)
    {
        string header = candidate.HeaderLine?.Text.Trim() ?? string.Empty;
        if (Regex.IsMatch(header, @"\b(?:has\s+)?entered\s+the\s+waiting\s+room\b", RegexOptions.IgnoreCase))
        {
            return true;
        }

        // The proven live OCR splits the toast after "entered the": the detector
        // stores "waiting room" as HeaderLine and the preceding OCR line as the
        // extracted participant text.
        return Regex.IsMatch(header, @"^waiting\s+room$", RegexOptions.IgnoreCase) &&
               Regex.IsMatch(candidate.ParticipantName ?? string.Empty, @"\b(?:has\s+)?entered\s+the\s*$", RegexOptions.IgnoreCase);
    }

    private static bool Matches(ToastSnapshot expected, ToastSnapshot current, out string reason)
    {
        if (!expected.Participant.Equals(current.Participant, StringComparison.OrdinalIgnoreCase))
        {
            reason = "participant changed";
            return false;
        }

        double distance = Math.Sqrt(
            Math.Pow(expected.AdmitCenter.X - current.AdmitCenter.X, 2) +
            Math.Pow(expected.AdmitCenter.Y - current.AdmitCenter.Y, 2));
        if (distance > CenterMovementTolerance)
        {
            reason = $"Admit center moved {distance:F1}px (limit {CenterMovementTolerance:F1}px)";
            return false;
        }

        double overlap = IntersectionOverUnion(expected.ToastBounds, current.ToastBounds);
        if (overlap < MinimumToastOverlap)
        {
            reason = $"toast overlap is {overlap:P0} (minimum {MinimumToastOverlap:P0})";
            return false;
        }

        double expectedViewOffsetX = expected.ViewCenter.X - expected.AdmitCenter.X;
        double expectedViewOffsetY = expected.ViewCenter.Y - expected.AdmitCenter.Y;
        double currentViewOffsetX = current.ViewCenter.X - current.AdmitCenter.X;
        double currentViewOffsetY = current.ViewCenter.Y - current.AdmitCenter.Y;
        double relationshipDelta = Math.Sqrt(
            Math.Pow(expectedViewOffsetX - currentViewOffsetX, 2) +
            Math.Pow(expectedViewOffsetY - currentViewOffsetY, 2));
        if (relationshipDelta > CenterMovementTolerance)
        {
            reason = $"Admit/View relationship changed {relationshipDelta:F1}px (limit {CenterMovementTolerance:F1}px)";
            return false;
        }

        reason = string.Empty;
        return true;
    }

    private static bool Contains(BoundingRectangleInfo bounds, double x, double y) =>
        bounds.Width > 0 && bounds.Height > 0 &&
        x >= bounds.X && x <= bounds.X + bounds.Width &&
        y >= bounds.Y && y <= bounds.Y + bounds.Height;

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

    private sealed record ToastSnapshot(
        string Participant,
        BoundingRectangleInfo ToastBounds,
        (double X, double Y) AdmitCenter,
        (double X, double Y) ViewCenter,
        DateTimeOffset Timestamp)
    {
        public static ToastSnapshot From(WaitingRoomToastCandidate candidate, DateTimeOffset timestamp) =>
            new(
                WaitingRoomParticipantIdentity.FromAcceptedCandidateText(candidate.ParticipantName).NormalizedName,
                candidate.ToastBounds,
                candidate.AdmitCenter,
                candidate.ViewWord!.Center,
                timestamp);
    }
}
