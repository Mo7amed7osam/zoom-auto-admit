namespace ZoomAutoAdmit.WindowsRuntime.Scheduling;

[Flags]
public enum ScheduleDays
{
    None = 0,
    Monday = 1 << 0,
    Tuesday = 1 << 1,
    Wednesday = 1 << 2,
    Thursday = 1 << 3,
    Friday = 1 << 4,
    Saturday = 1 << 5,
    Sunday = 1 << 6,
    EveryDay = Monday | Tuesday | Wednesday | Thursday | Friday | Saturday | Sunday
}

public sealed record MeetingSchedule(
    Guid Id,
    string Name,
    string MeetingUrl,
    string AccountId,
    TimeOnly Time,
    ScheduleDays Days,
    bool Enabled,
    DateOnly? LastTriggeredDate = null);

public static class ScheduleDaysExtensions
{
    public static bool Includes(this ScheduleDays days, DayOfWeek day) =>
        days.HasFlag(day switch
        {
            DayOfWeek.Monday => ScheduleDays.Monday,
            DayOfWeek.Tuesday => ScheduleDays.Tuesday,
            DayOfWeek.Wednesday => ScheduleDays.Wednesday,
            DayOfWeek.Thursday => ScheduleDays.Thursday,
            DayOfWeek.Friday => ScheduleDays.Friday,
            DayOfWeek.Saturday => ScheduleDays.Saturday,
            DayOfWeek.Sunday => ScheduleDays.Sunday,
            _ => ScheduleDays.None
        });
}
