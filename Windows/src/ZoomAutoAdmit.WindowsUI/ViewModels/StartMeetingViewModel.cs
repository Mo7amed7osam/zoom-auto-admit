using System.Collections.ObjectModel;
using System.Windows.Input;
using ZoomAutoAdmit.WindowsRuntime;
using ZoomAutoAdmit.WindowsUI.Infrastructure;
using ZoomAutoAdmit.WindowsUI.Services;

namespace ZoomAutoAdmit.WindowsUI.ViewModels;

public sealed class StartMeetingViewModel : ObservableObject
{
    private readonly IWindowsUiService _service;
    private WindowsMeetingAccountMetadata? _selectedAccount;
    private string _meetingUrl = string.Empty;
    private EnginePreference _enginePreference;
    private string _statusMessage = string.Empty;

    public StartMeetingViewModel(IWindowsUiService service)
    {
        _service = service;
        StartCommand = new AsyncRelayCommand(_ => StartAsync());
    }

    public event Action? MeetingStarted;
    public ObservableCollection<WindowsMeetingAccountMetadata> Accounts { get; } = [];
    public IReadOnlyList<EnginePreference> EnginePreferences { get; } = Enum.GetValues<EnginePreference>();
    public WindowsMeetingAccountMetadata? SelectedAccount
    {
        get => _selectedAccount;
        set
        {
            if (!SetProperty(ref _selectedAccount, value)) return;
            // Never carry a different group's link into the newly selected account.
            MeetingUrl = value?.DefaultMeetingUrl ?? string.Empty;
            StatusMessage = value == null ? string.Empty : string.IsNullOrEmpty(MeetingUrl)
                ? "No saved meeting link. Enter one here, or save it permanently in Accounts."
                : "Saved group link loaded. Changes here apply to this launch only; edit Accounts to save a new default.";
        }
    }
    public string MeetingUrl { get => _meetingUrl; set => SetProperty(ref _meetingUrl, value); }
    public EnginePreference EnginePreference { get => _enginePreference; set => SetProperty(ref _enginePreference, value); }
    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public ICommand StartCommand { get; }

    public async Task RefreshAccountsAsync()
    {
        string? selectedId = SelectedAccount?.AccountId;
        var accounts = await _service.GetAccountsAsync();
        Accounts.Clear();
        foreach (var account in accounts) Accounts.Add(account);
        SelectedAccount = Accounts.FirstOrDefault(account => account.AccountId == selectedId) ?? Accounts.FirstOrDefault();
    }

    public async Task StartAsync()
    {
        if (SelectedAccount == null) { StatusMessage = "Select an account."; return; }
        if (string.IsNullOrWhiteSpace(MeetingUrl)) { StatusMessage = "Enter a meeting URL."; return; }
        try
        {
            StatusMessage = "Starting meeting...";
            var session = await _service.StartMeetingAsync(
                SelectedAccount.AccountId,
                MeetingUrl,
                EnginePreference);
            StatusMessage = $"Meeting started with {session.EngineType}.";
            MeetingStarted?.Invoke();
        }
        catch (Exception ex) { StatusMessage = ex.Message; }
    }
}
