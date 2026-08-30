using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows.Input;
using ZoomAutoAdmit.WindowsRuntime;
using ZoomAutoAdmit.WindowsRuntime.Scheduling;
using ZoomAutoAdmit.WindowsUI.Infrastructure;
using ZoomAutoAdmit.WindowsUI.Services;

namespace ZoomAutoAdmit.WindowsUI.ViewModels;

public sealed class SchedulesViewModel : ObservableObject, IDisposable
{
    private readonly IWindowsUiService _service;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private MeetingSchedule? _selectedSchedule;
    private Guid _editingId;
    private string _name = string.Empty;
    private string _meetingUrl = string.Empty;
    private WindowsMeetingAccountMetadata? _selectedAccount;
    private string _time = "09:00";
    private bool _enabled = true;
    private bool _monday;
    private bool _tuesday;
    private bool _wednesday;
    private bool _thursday;
    private bool _friday;
    private bool _saturday;
    private bool _sunday;
    private string _statusMessage = string.Empty;
    private string _executionStatus = "Scheduler ready.";

    public SchedulesViewModel(IWindowsUiService service)
    {
        _service = service;
        NewCommand = new RelayCommand(_ => ClearEditor());
        SaveCommand = new AsyncRelayCommand(_ => SaveAsync());
        DeleteCommand = new AsyncRelayCommand(_ => DeleteAsync());
        RefreshCommand = new AsyncRelayCommand(_ => RefreshAsync());
        _service.StatusChanged += OnStatusChanged;
    }

    public ObservableCollection<MeetingSchedule> Items { get; } = [];
    public ObservableCollection<WindowsMeetingAccountMetadata> Accounts { get; } = [];
    public MeetingSchedule? SelectedSchedule
    {
        get => _selectedSchedule;
        set
        {
            if (!SetProperty(ref _selectedSchedule, value) || value == null) return;
            _editingId = value.Id;
            Name = value.Name;
            MeetingUrl = value.MeetingUrl;
            SelectedAccount = Accounts.FirstOrDefault(account => account.AccountId.Equals(value.AccountId, StringComparison.OrdinalIgnoreCase));
            Time = value.Time.ToString("HH:mm", CultureInfo.InvariantCulture);
            Enabled = value.Enabled;
            Monday = value.Days.HasFlag(ScheduleDays.Monday);
            Tuesday = value.Days.HasFlag(ScheduleDays.Tuesday);
            Wednesday = value.Days.HasFlag(ScheduleDays.Wednesday);
            Thursday = value.Days.HasFlag(ScheduleDays.Thursday);
            Friday = value.Days.HasFlag(ScheduleDays.Friday);
            Saturday = value.Days.HasFlag(ScheduleDays.Saturday);
            Sunday = value.Days.HasFlag(ScheduleDays.Sunday);
        }
    }
    public string Name { get => _name; set => SetProperty(ref _name, value); }
    public string MeetingUrl { get => _meetingUrl; set => SetProperty(ref _meetingUrl, value); }
    public WindowsMeetingAccountMetadata? SelectedAccount { get => _selectedAccount; set => SetProperty(ref _selectedAccount, value); }
    public string Time { get => _time; set => SetProperty(ref _time, value); }
    public bool Enabled { get => _enabled; set => SetProperty(ref _enabled, value); }
    public bool Monday { get => _monday; set => SetProperty(ref _monday, value); }
    public bool Tuesday { get => _tuesday; set => SetProperty(ref _tuesday, value); }
    public bool Wednesday { get => _wednesday; set => SetProperty(ref _wednesday, value); }
    public bool Thursday { get => _thursday; set => SetProperty(ref _thursday, value); }
    public bool Friday { get => _friday; set => SetProperty(ref _friday, value); }
    public bool Saturday { get => _saturday; set => SetProperty(ref _saturday, value); }
    public bool Sunday { get => _sunday; set => SetProperty(ref _sunday, value); }
    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public string ExecutionStatus { get => _executionStatus; private set => SetProperty(ref _executionStatus, value); }
    public ICommand NewCommand { get; }
    public ICommand SaveCommand { get; }
    public ICommand DeleteCommand { get; }
    public ICommand RefreshCommand { get; }

    public async Task RefreshAsync()
    {
        var accounts = await _service.GetAccountsAsync();
        var schedules = await _service.GetSchedulesAsync();
        Accounts.Clear();
        foreach (var account in accounts) Accounts.Add(account);
        Items.Clear();
        foreach (var schedule in schedules) Items.Add(schedule);
    }

    public async Task SaveAsync()
    {
        try
        {
            if (SelectedAccount == null) throw new InvalidOperationException("Select an account.");
            if (!TimeOnly.TryParseExact(Time, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsedTime))
                throw new InvalidOperationException("Time must use HH:mm format.");
            ScheduleDays days = SelectedDays();
            var existing = Items.FirstOrDefault(item => item.Id == _editingId);
            await _service.SaveScheduleAsync(new MeetingSchedule(
                _editingId == Guid.Empty ? Guid.NewGuid() : _editingId,
                Name.Trim(),
                MeetingUrl.Trim(),
                SelectedAccount.AccountId,
                parsedTime,
                days,
                Enabled,
                existing?.LastTriggeredDate));
            await RefreshAsync();
            StatusMessage = "Schedule saved.";
        }
        catch (Exception ex) { StatusMessage = ex.Message; }
    }

    public async Task DeleteAsync()
    {
        if (_editingId == Guid.Empty) return;
        bool deleted = await _service.DeleteScheduleAsync(_editingId);
        await RefreshAsync();
        ClearEditor();
        StatusMessage = deleted ? "Schedule deleted." : "Schedule was not found.";
    }

    private ScheduleDays SelectedDays()
    {
        ScheduleDays days = ScheduleDays.None;
        if (Monday) days |= ScheduleDays.Monday;
        if (Tuesday) days |= ScheduleDays.Tuesday;
        if (Wednesday) days |= ScheduleDays.Wednesday;
        if (Thursday) days |= ScheduleDays.Thursday;
        if (Friday) days |= ScheduleDays.Friday;
        if (Saturday) days |= ScheduleDays.Saturday;
        if (Sunday) days |= ScheduleDays.Sunday;
        return days;
    }

    private void ClearEditor()
    {
        SelectedSchedule = null;
        _editingId = Guid.Empty;
        Name = string.Empty;
        MeetingUrl = string.Empty;
        SelectedAccount = Accounts.FirstOrDefault();
        Time = "09:00";
        Enabled = true;
        Monday = Tuesday = Wednesday = Thursday = Friday = Saturday = Sunday = false;
        StatusMessage = string.Empty;
    }

    private void OnStatusChanged(UiActionStatus status)
    {
        if (status.LastAction != "Scheduled meeting") return;
        string text = string.IsNullOrWhiteSpace(status.ErrorMessage)
            ? status.CurrentOperation
            : $"{status.CurrentOperation}: {status.ErrorMessage}";
        if (_context == null || SynchronizationContext.Current == _context) ExecutionStatus = text;
        else _context.Post(_ => ExecutionStatus = text, null);
    }

    public void Dispose() => _service.StatusChanged -= OnStatusChanged;
}
