namespace ZoomAutoAdmit.Core.Meetings;

public enum MeetingState
{
    Scheduled,
    Launching,
    SwitchingAccount,
    Joining,
    Preparing,
    Active,
    Monitoring,
    Ended,
    Failed
}

public sealed record MeetingStateTransition(
    MeetingState State,
    DateTimeOffset Timestamp,
    string? Detail);
