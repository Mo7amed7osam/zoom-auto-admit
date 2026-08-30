using ZoomAutoAdmit.WebAutomation.Browser;
using Xunit;

namespace ZoomAutoAdmit.WebAutomation.Tests;

public sealed class ZoomProfileManagerTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "ZoomAutoAdmitTests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public void FirstUseCreatesDefaultProfileAndRequiresVisibleBrowser()
    {
        var manager = new ZoomProfileManager(_root);

        var profile = manager.GetOrCreate("default");
        var plan = manager.CreateLaunchPlan(profile, forceHeaded: false);

        Assert.Equal("Default", profile.Name);
        Assert.True(Directory.Exists(profile.DirectoryPath));
        Assert.False(profile.HasReusableSession);
        Assert.False(plan.Headless);
    }

    [Fact]
    public void ReadyMarkerIsReusedByFutureManagerAndEnablesHeadlessMode()
    {
        var firstManager = new ZoomProfileManager(_root);
        var initialized = firstManager.MarkSessionReady(firstManager.GetOrCreate("account1"));

        var futureManager = new ZoomProfileManager(_root);
        var reused = futureManager.GetOrCreate("account1");
        var plan = futureManager.CreateLaunchPlan(reused, forceHeaded: false);

        Assert.True(initialized.HasReusableSession);
        Assert.True(reused.HasReusableSession);
        Assert.True(plan.Headless);
        Assert.Single(Directory.GetFiles(reused.DirectoryPath));
        Assert.DoesNotContain("password", File.ReadAllText(reused.ReadyMarkerPath), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void HeadedOptionOverridesReusableSessionForManualRefresh()
    {
        var manager = new ZoomProfileManager(_root);
        var profile = manager.MarkSessionReady(manager.GetOrCreate("account2"));

        Assert.False(manager.CreateLaunchPlan(profile, forceHeaded: true).Headless);
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("account/other")]
    [InlineData("")]
    public void UnsafeProfileNamesAreRejected(string name)
    {
        var manager = new ZoomProfileManager(_root);

        Assert.Throws<ArgumentException>(() => manager.GetOrCreate(name));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }
}
