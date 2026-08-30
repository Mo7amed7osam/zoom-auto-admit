using ZoomAutoAdmit.WindowsUI.Infrastructure;
using ZoomAutoAdmit.WindowsUI.Services;

namespace ZoomAutoAdmit.WindowsUI.ViewModels;

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private int _selectedTabIndex;

    public MainViewModel(IWindowsUiService service)
    {
        Dashboard = new DashboardViewModel(service);
        StartMeeting = new StartMeetingViewModel(service);
        Accounts = new AccountsViewModel(service);
        Schedules = new SchedulesViewModel(service);
        Logs = new LogsViewModel();
        StartMeeting.MeetingStarted += OnMeetingStarted;
        Accounts.AccountsChanged += OnAccountsChanged;
        ShowStartMeetingCommand = new RelayCommand(_ => SelectedTabIndex = 1);
    }

    public DashboardViewModel Dashboard { get; }
    public StartMeetingViewModel StartMeeting { get; }
    public AccountsViewModel Accounts { get; }
    public SchedulesViewModel Schedules { get; }
    public LogsViewModel Logs { get; }
    public RelayCommand ShowStartMeetingCommand { get; }
    public int SelectedTabIndex
    {
        get => _selectedTabIndex;
        set
        {
            if (SetProperty(ref _selectedTabIndex, value))
                WindowsUiRuntimeLog.Write("NAVIGATION", $"Selected tab index: {value}.");
        }
    }

    public async Task InitializeAsync()
    {
        List<Exception> failures = [];
        await TryInitializeAsync(Accounts.RefreshAsync, failures);
        await TryInitializeAsync(StartMeeting.RefreshAccountsAsync, failures);
        await TryInitializeAsync(Schedules.RefreshAsync, failures);
        await TryInitializeAsync(Dashboard.RefreshAsync, failures);
        if (failures.Count > 0)
            throw new AggregateException("One or more UI services could not be initialized.", failures);
    }

    private static async Task TryInitializeAsync(Func<Task> initialize, List<Exception> failures)
    {
        try { await initialize(); }
        catch (Exception ex) { failures.Add(ex); }
    }

    private async void OnMeetingStarted() => await Dashboard.RefreshAsync();
    private async void OnAccountsChanged()
    {
        await StartMeeting.RefreshAccountsAsync();
        await Schedules.RefreshAsync();
    }

    public void Dispose()
    {
        StartMeeting.MeetingStarted -= OnMeetingStarted;
        Accounts.AccountsChanged -= OnAccountsChanged;
        Logs.Dispose();
        Dashboard.Dispose();
        Schedules.Dispose();
    }
}
