using System.Runtime.InteropServices;
using System.Text.Json;
using ZoomAutoAdmit.Core.Meetings;

namespace ZoomAutoAdmit.WindowsRuntime;

public sealed record WindowsMeetingAccountMetadata(
    string AccountId,
    string DisplayName,
    string CredentialReference);

public interface IWindowsCredentialReferenceResolver
{
    bool CanResolve(string credentialReference);
}

public sealed class WindowsCredentialManagerReferenceResolver : IWindowsCredentialReferenceResolver
{
    private const int CredentialTypeGeneric = 1;

    public bool CanResolve(string credentialReference)
    {
        if (!OperatingSystem.IsWindows() || string.IsNullOrWhiteSpace(credentialReference)) return false;
        string target = credentialReference.StartsWith("wincred:", StringComparison.OrdinalIgnoreCase)
            ? credentialReference["wincred:".Length..]
            : credentialReference;
        if (string.IsNullOrWhiteSpace(target)) return false;
        if (!CredRead(target, CredentialTypeGeneric, 0, out var credentialPointer)) return false;
        CredFree(credentialPointer);
        return true;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string target,
        int type,
        int reservedFlag,
        out IntPtr credentialPointer);

    [DllImport("advapi32.dll", SetLastError = false)]
    private static extern void CredFree(IntPtr credentialPointer);
}

public sealed class WindowsMeetingAccountManager : IMeetingAccountManager
{
    private readonly string _metadataPath;
    private readonly IWindowsCredentialReferenceResolver _credentialResolver;

    public WindowsMeetingAccountManager(
        string? metadataPath = null,
        IWindowsCredentialReferenceResolver? credentialResolver = null)
    {
        _metadataPath = Path.GetFullPath(metadataPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ZoomAutoAdmit",
            "Accounts",
            "accounts.json"));
        _credentialResolver = credentialResolver ?? new WindowsCredentialManagerReferenceResolver();
    }

    public async Task<MeetingAccount?> LoadAsync(
        string accountId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(accountId) || !File.Exists(_metadataPath)) return null;
        await using var stream = new FileStream(
            _metadataPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 4096,
            useAsync: true);
        var accounts = await JsonSerializer.DeserializeAsync<List<WindowsMeetingAccountMetadata>>(
            stream,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true },
            cancellationToken) ?? [];
        var account = accounts.FirstOrDefault(candidate =>
            candidate.AccountId.Equals(accountId.Trim(), StringComparison.OrdinalIgnoreCase));
        if (account == null || !_credentialResolver.CanResolve(account.CredentialReference)) return null;

        // Only the secure target reference crosses the orchestration boundary. Credential
        // secret bytes remain owned by Windows Credential Manager and are never serialized.
        return new MeetingAccount(
            account.AccountId,
            account.DisplayName,
            account.CredentialReference);
    }
}
