namespace ZoomAutoAdmit.Core.Sessions;

public sealed class SessionCoordinator
{
    private readonly object _allocationSync = new();
    private readonly ActiveSessionRegistry _registry;
    private readonly SessionAllocationPolicy _policy;

    public SessionCoordinator(
        ActiveSessionRegistry? registry = null,
        SessionAllocationPolicy? policy = null)
    {
        _registry = registry ?? new ActiveSessionRegistry();
        _policy = policy ?? new SessionAllocationPolicy();
    }

    public IReadOnlyList<ActiveSession> ActiveSessions => _registry.GetActive();

    public SessionAllocationResult Allocate(
        string accountId,
        DateTimeOffset? startTime = null,
        Guid? sessionId = null)
    {
        string webProfileName;
        try
        {
            webProfileName = AccountWebProfile.ForAccount(accountId);
        }
        catch (ArgumentException ex)
        {
            return SessionAllocationResult.Failure(
                SessionAllocationError.InvalidAccountId,
                ex.Message);
        }

        Guid id = sessionId ?? Guid.NewGuid();
        DateTimeOffset startedAt = startTime ?? DateTimeOffset.UtcNow;
        lock (_allocationSync)
        {
            if (_registry.TryGet(id, out _))
            {
                return SessionAllocationResult.Failure(
                    SessionAllocationError.DuplicateSessionId,
                    $"Session '{id}' is already registered.");
            }

            // A direct registry user could reserve Desktop between policy evaluation and
            // registration. Re-evaluate once so that race cleanly falls back to Web.
            for (int attempt = 0; attempt < 2; attempt++)
            {
                var decision = _policy.Decide(_registry.GetActive(), webProfileName);
                if (!decision.IsAllowed || decision.EngineType == null)
                {
                    return SessionAllocationResult.Failure(
                        decision.Error,
                        decision.ErrorMessage ?? "The session could not be allocated.");
                }

                var session = new ActiveSession(
                    id,
                    accountId.Trim(),
                    decision.EngineType.Value,
                    startedAt,
                    SessionStatus.Allocated,
                    decision.EngineType == SessionEngineType.Web ? webProfileName : null);
                if (_registry.TryAdd(session, out var error, out var errorMessage))
                    return SessionAllocationResult.Success(session);

                if (error != SessionAllocationError.DesktopOccupied)
                    return SessionAllocationResult.Failure(
                        error,
                        errorMessage ?? "The session reservation failed.");
            }

            return SessionAllocationResult.Failure(
                SessionAllocationError.DesktopOccupied,
                "The Zoom Desktop engine became occupied while the session was being allocated.");
        }
    }

    public bool TryUpdateStatus(Guid sessionId, SessionStatus status, out ActiveSession? updated) =>
        _registry.TryUpdateStatus(sessionId, status, out updated);

    public bool Release(Guid sessionId) => _registry.Remove(sessionId);
}
