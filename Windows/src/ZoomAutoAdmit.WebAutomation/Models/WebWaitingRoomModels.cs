namespace ZoomAutoAdmit.WebAutomation.Models;

public sealed record WebWaitingParticipant(string Name, string Identity);

public sealed record WebWaitingRoomSnapshot(
    bool MeetingActive,
    bool WaitingRoomExists,
    int WaitingCount,
    bool AdmitAllAvailable,
    IReadOnlyList<WebWaitingParticipant> Participants)
{
    public IReadOnlyList<string> JoinedParticipantIdentities { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ArrivalNotificationParticipantIdentities { get; init; } = Array.Empty<string>();

    public static WebWaitingRoomSnapshot NoMeeting =>
        new(false, false, 0, false, Array.Empty<WebWaitingParticipant>());
}

public enum WebAdmissionKind
{
    None,
    AdmitAll,
    Single
}

public sealed record WebAdmissionDecision(
    WebAdmissionKind Kind,
    WebWaitingParticipant? Participant,
    string Reason);

public sealed record WebAdmissionVerification(
    bool IsVerified,
    bool ShouldRetry,
    string Reason);
