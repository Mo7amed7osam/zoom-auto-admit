using Microsoft.Playwright;
using ZoomAutoAdmit.Core.Formatting;

namespace ZoomAutoAdmit.WebAutomation.Browser;

public sealed class ZoomBrowserSession : IAsyncDisposable
{
    private readonly IPlaywright _playwright;
    private readonly object _pageSync = new();
    private readonly HashSet<IPage> _trackedPages = [];
    private IPage? _activeMeetingPage;
    private int _meetingPageSelected;
    private int _disposed;

    internal ZoomBrowserSession(
        IPlaywright playwright,
        IBrowserContext context,
        ZoomBrowserLaunchPlan plan)
    {
        _playwright = playwright;
        Context = context;
        Profile = plan.Profile;
        IsHeadless = plan.Headless;
        Context.Page += OnPageCreated;
        foreach (var page in Context.Pages.ToArray()) TrackPage(page);
    }

    public IBrowserContext Context { get; }
    public ZoomBrowserProfile Profile { get; internal set; }
    public bool IsHeadless { get; }
    public IPage? ActiveMeetingPage => Volatile.Read(ref _activeMeetingPage);
    public bool MeetingPageWasSelected => Volatile.Read(ref _meetingPageSelected) != 0;

    public async Task SelectMeetingPageAsync(IPage page, bool rediscovered = false)
    {
        ArgumentNullException.ThrowIfNull(page);
        TrackPage(page);
        Volatile.Write(ref _activeMeetingPage, page);
        Interlocked.Exchange(ref _meetingPageSelected, 1);
        ConsoleLogger.Success(rediscovered ? "MEETING_PAGE_REDISCOVERED" : "MEETING_PAGE_SELECTED");
        ConsoleLogger.Info($"MEETING_PAGE_URL: {page.Url}");
        ConsoleLogger.Success("MEETING_PAGE_ACTIVE");

        foreach (var extraPage in Context.Pages.Where(candidate =>
                     !ReferenceEquals(candidate, page) && !candidate.IsClosed).ToArray())
        {
            await extraPage.CloseAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        Context.Page -= OnPageCreated;
        try { await Context.CloseAsync(); }
        finally { _playwright.Dispose(); }
    }

    private void OnPageCreated(object? sender, IPage page) => TrackPage(page);

    private void TrackPage(IPage page)
    {
        lock (_pageSync)
        {
            if (!_trackedPages.Add(page)) return;
        }
        page.Close += OnPageClosed;
        ConsoleLogger.Info("BROWSER_PAGE_CREATED");
    }

    private void OnPageClosed(object? sender, IPage page)
    {
        ConsoleLogger.Info("PAGE_CLOSED");
    }
}
