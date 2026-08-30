using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ZoomAutoAdmit.Core.Sessions;

public enum SessionEngineType
{
    Desktop,
    Web
}

public enum SessionStatus
{
    Allocated,
    Starting,
    Active,
    Stopping,
    Completed,
    Failed
}

public sealed record ActiveSession(
    Guid SessionId,
    string AccountId,
    SessionEngineType EngineType,
    DateTimeOffset StartTime,
    SessionStatus Status,
    string? WebProfileName)
{
    public bool OccupiesCapacity => Status is not SessionStatus.Completed and not SessionStatus.Failed;
}

public enum SessionAllocationError
{
    None,
    InvalidAccountId,
    DuplicateSessionId,
    DesktopOccupied,
    WebProfileLocked
}

public sealed record SessionAllocationResult(
    bool IsSuccess,
    ActiveSession? Session,
    SessionAllocationError Error,
    string? ErrorMessage)
{
    public static SessionAllocationResult Success(ActiveSession session) =>
        new(true, session, SessionAllocationError.None, null);

    public static SessionAllocationResult Failure(SessionAllocationError error, string message) =>
        new(false, null, error, message);
}

public static class AccountWebProfile
{
    private static readonly Regex SafeDirectoryName = new(
        @"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static string ForAccount(string accountId)
    {
        string normalized = accountId?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(normalized))
            throw new ArgumentException("Account ID is required.", nameof(accountId));

        if (SafeDirectoryName.IsMatch(normalized)) return normalized;

        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return $"account-{Convert.ToHexString(digest.AsSpan(0, 16)).ToLowerInvariant()}";
    }
}
