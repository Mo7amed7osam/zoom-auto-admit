namespace ZoomAutoAdmit.Core.Sessions;

public sealed record SessionAllocationDecision(
    bool IsAllowed,
    SessionEngineType? EngineType,
    SessionAllocationError Error,
    string? ErrorMessage)
{
    public static SessionAllocationDecision Use(SessionEngineType engineType) =>
        new(true, engineType, SessionAllocationError.None, null);

    public static SessionAllocationDecision Reject(SessionAllocationError error, string message) =>
        new(false, null, error, message);
}

public sealed class SessionAllocationPolicy
{
    public SessionAllocationDecision Decide(
        IReadOnlyCollection<ActiveSession> activeSessions,
        string accountWebProfileName)
    {
        bool desktopOccupied = activeSessions.Any(session =>
            session.OccupiesCapacity && session.EngineType == SessionEngineType.Desktop);
        if (!desktopOccupied)
            return SessionAllocationDecision.Use(SessionEngineType.Desktop);

        bool webProfileLocked = activeSessions.Any(session =>
            session.OccupiesCapacity &&
            session.EngineType == SessionEngineType.Web &&
            string.Equals(
                session.WebProfileName,
                accountWebProfileName,
                StringComparison.OrdinalIgnoreCase));
        return webProfileLocked
            ? SessionAllocationDecision.Reject(
                SessionAllocationError.WebProfileLocked,
                $"Web profile '{accountWebProfileName}' is already locked by another active session.")
            : SessionAllocationDecision.Use(SessionEngineType.Web);
    }
}
