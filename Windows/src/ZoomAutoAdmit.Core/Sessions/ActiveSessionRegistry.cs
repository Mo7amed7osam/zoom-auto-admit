namespace ZoomAutoAdmit.Core.Sessions;

public sealed class ActiveSessionRegistry
{
    private readonly object _sync = new();
    private readonly Dictionary<Guid, ActiveSession> _sessions = [];

    public IReadOnlyList<ActiveSession> GetAll()
    {
        lock (_sync)
        {
            return _sessions.Values.OrderBy(session => session.StartTime).ToArray();
        }
    }

    public IReadOnlyList<ActiveSession> GetActive()
    {
        lock (_sync)
        {
            return _sessions.Values
                .Where(session => session.OccupiesCapacity)
                .OrderBy(session => session.StartTime)
                .ToArray();
        }
    }

    public bool TryGet(Guid sessionId, out ActiveSession? session)
    {
        lock (_sync)
        {
            return _sessions.TryGetValue(sessionId, out session);
        }
    }

    public bool TryAdd(
        ActiveSession session,
        out SessionAllocationError error,
        out string? errorMessage)
    {
        lock (_sync)
        {
            if (_sessions.ContainsKey(session.SessionId))
            {
                error = SessionAllocationError.DuplicateSessionId;
                errorMessage = $"Session '{session.SessionId}' is already registered.";
                return false;
            }

            if (session.OccupiesCapacity && session.EngineType == SessionEngineType.Desktop &&
                _sessions.Values.Any(candidate =>
                    candidate.OccupiesCapacity && candidate.EngineType == SessionEngineType.Desktop))
            {
                error = SessionAllocationError.DesktopOccupied;
                errorMessage = "The Zoom Desktop engine is already occupied by another active session.";
                return false;
            }

            if (session.OccupiesCapacity && session.EngineType == SessionEngineType.Web &&
                _sessions.Values.Any(candidate =>
                    candidate.OccupiesCapacity &&
                    candidate.EngineType == SessionEngineType.Web &&
                    string.Equals(
                        candidate.WebProfileName,
                        session.WebProfileName,
                        StringComparison.OrdinalIgnoreCase)))
            {
                error = SessionAllocationError.WebProfileLocked;
                errorMessage = $"Web profile '{session.WebProfileName}' is already locked by another active session.";
                return false;
            }

            _sessions.Add(session.SessionId, session);
            error = SessionAllocationError.None;
            errorMessage = null;
            return true;
        }
    }

    public bool TryUpdateStatus(Guid sessionId, SessionStatus status, out ActiveSession? updated)
    {
        lock (_sync)
        {
            if (!_sessions.TryGetValue(sessionId, out var current))
            {
                updated = null;
                return false;
            }

            updated = current with { Status = status };
            _sessions[sessionId] = updated;
            return true;
        }
    }

    public bool Remove(Guid sessionId)
    {
        lock (_sync)
        {
            return _sessions.Remove(sessionId);
        }
    }
}
