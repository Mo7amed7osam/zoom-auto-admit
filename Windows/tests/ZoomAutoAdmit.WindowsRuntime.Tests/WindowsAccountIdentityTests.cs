using System.Text.Json;
using Xunit;
using ZoomAutoAdmit.Core.Meetings;

namespace ZoomAutoAdmit.WindowsRuntime.Tests;

public sealed class WindowsAccountIdentityTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "ZoomIdentityTests", Guid.NewGuid().ToString("N"));
    private string AccountPath => Path.Combine(root, "accounts.json");
    private WindowsMeetingAccountManager Manager() => new(AccountPath, new NoSecrets(), new WindowsAccountWebProfileMapper(Path.Combine(root, "Profiles")));
    private static WindowsMeetingAccountMetadata Account(string id, string email) =>
        new(id, "same display name", "") { ZoomEmail = email };

    [Fact]
    public async Task S7AndS8RemainDistinctWithoutAnyPassword()
    {
        var manager = Manager();
        await manager.UpsertAsync(Account("S7", "DEPI+20@EYOUTHLEARNING.COM"));
        await manager.UpsertAsync(Account("S8", "depi+21@eyouthlearning.com"));
        Assert.Equal("depi+20@eyouthlearning.com", (await manager.LoadAsync("S7"))!.ZoomEmail);
        Assert.Equal("depi+21@eyouthlearning.com", (await manager.LoadAsync("S8"))!.ZoomEmail);
        Assert.DoesNotContain("password", await File.ReadAllTextAsync(AccountPath), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExplicitIdentityWinsOverIncorrectCredentialUsername()
    {
        string? selected = null;
        var platform = new WindowsDesktopMeetingPlatform(_ => throw new Exception("Do not infer email from credentials"),
            (email, _) => { selected = email; return Task.FromResult(MeetingOperationResult.Success()); });
        var result = await platform.SwitchAccountAsync(new MeetingAccount("S7", "same name", "wincred:wrong")
            { ZoomEmail = "depi+20@eyouthlearning.com" }, CancellationToken.None);
        Assert.True(result.IsSuccess);
        Assert.Equal("depi+20@eyouthlearning.com", selected);
    }

    [Theory]
    [InlineData("not-an-email")]
    [InlineData("depi+20 @eyouthlearning.com")]
    [InlineData("Person <depi+20@eyouthlearning.com>")]
    public async Task InvalidIdentityIsRejectedBeforeWriting(string email)
    {
        await Assert.ThrowsAsync<ArgumentException>(() => Manager().UpsertAsync(Account("S7", email)));
        Assert.False(File.Exists(AccountPath));
    }

    [Fact]
    public async Task DuplicateEmailIsRejectedWithoutChangingFile()
    {
        var manager = Manager();
        await manager.UpsertAsync(Account("S7", "depi+20@eyouthlearning.com"));
        string before = await File.ReadAllTextAsync(AccountPath);
        await Assert.ThrowsAsync<InvalidOperationException>(() => manager.UpsertAsync(Account("S8", "DEPI+20@EYOUTHLEARNING.COM")));
        Assert.Equal(before, await File.ReadAllTextAsync(AccountPath));
    }

    [Fact]
    public async Task SaveKeepsPreviousVersionAsBackup()
    {
        var manager = Manager();
        await manager.UpsertAsync(Account("S7", "depi+20@eyouthlearning.com"));
        string before = await File.ReadAllTextAsync(AccountPath);
        await manager.UpsertAsync(Account("S8", "depi+21@eyouthlearning.com"));
        Assert.Equal(before, await File.ReadAllTextAsync(AccountPath + ".bak"));
    }

    [Fact]
    public async Task LegacyMetadataRoundTripsWithoutInventingEmail()
    {
        Directory.CreateDirectory(root);
        await File.WriteAllTextAsync(AccountPath, """
            [{"accountId":"legacy","displayName":"Legacy","credentialReference":"wincred:legacy","preferredEngine":"Auto"}]
            """);
        var manager = Manager();
        var old = Assert.Single(await manager.ListConfiguredAsync());
        Assert.Null(old.ZoomEmail);
        Assert.Equal("wincred:legacy", old.CredentialReference);
        await manager.UpsertAsync(old);
        Assert.Null(Assert.Single(await manager.ListConfiguredAsync()).ZoomEmail);
    }

    [Fact]
    public async Task MultipleManagersInSameProcessDoNotLoseAccounts()
    {
        await Task.WhenAll(Manager().UpsertAsync(Account("S7", "depi+20@eyouthlearning.com")),
            Manager().UpsertAsync(Account("S8", "depi+21@eyouthlearning.com")));
        Assert.Equal(2, (await Manager().ListConfiguredAsync()).Count);
    }

    [Fact]
    public async Task LoadingNewRecordDoesNotReadOrRequireCredentialSecrets()
    {
        var manager = Manager();
        await manager.UpsertAsync(Account("S7", "depi+20@eyouthlearning.com") with { CredentialReference = "wincred:old-wrong-reference" });
        Assert.NotNull(await manager.LoadAsync("S7"));
    }

    private sealed class NoSecrets : IWindowsCredentialReferenceResolver
    {
        public bool CanResolve(string reference) => throw new Exception("Explicit-email accounts must use saved sessions, not credentials.");
    }

    [Fact]
    public async Task DefaultMeetingLinkPersistsAndCanBeReplacedWithoutChangingIdentity()
    {
        var manager = Manager();
        var original = Account("S7", "depi+20@eyouthlearning.com") with
            { DefaultMeetingUrl = " https://zoom.us/j/123456789?pwd=Example%2BValue " };
        await manager.UpsertAsync(original);
        var saved = Assert.Single(await Manager().ListConfiguredAsync());
        Assert.Equal(original.DefaultMeetingUrl.Trim(), saved.DefaultMeetingUrl);
        await manager.UpsertAsync(saved with { DefaultMeetingUrl = "https://us02web.zoom.us/j/987654321?pwd=NewValue" });
        var edited = Assert.Single(await Manager().ListConfiguredAsync());
        Assert.Equal("https://us02web.zoom.us/j/987654321?pwd=NewValue", edited.DefaultMeetingUrl);
        Assert.Equal(saved.ZoomEmail, edited.ZoomEmail);
        Assert.Equal(saved.AccountId, edited.AccountId);
        Assert.Contains("123456789", await File.ReadAllTextAsync(AccountPath + ".bak"));
        await manager.UpsertAsync(edited with { DefaultMeetingUrl = "" });
        Assert.Null(Assert.Single(await Manager().ListConfiguredAsync()).DefaultMeetingUrl);
    }

    [Theory]
    [InlineData("http://zoom.us/j/123456789")]
    [InlineData("https://zoom.us.evil.example/j/123456789")]
    [InlineData("not a URL")]
    [InlineData("https://user:password@zoom.us/j/123456789")]
    public async Task InvalidDefaultMeetingLinkDoesNotOverwriteSavedAccount(string url)
    {
        var manager = Manager();
        var account = Account("S7", "depi+20@eyouthlearning.com");
        await manager.UpsertAsync(account);
        var before = await File.ReadAllTextAsync(AccountPath);
        await Assert.ThrowsAsync<ArgumentException>(() => manager.UpsertAsync(account with { DefaultMeetingUrl = url }));
        Assert.Equal(before, await File.ReadAllTextAsync(AccountPath));
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
}
