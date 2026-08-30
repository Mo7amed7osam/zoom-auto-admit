using System.Windows;
using System.Windows.Threading;
using ZoomAutoAdmit.Inspector.Runtime;
using ZoomAutoAdmit.WindowsUI.Infrastructure;
using ZoomAutoAdmit.WindowsUI.Services;
using ZoomAutoAdmit.WindowsUI.ViewModels;

namespace ZoomAutoAdmit.WindowsUI;

public partial class App : Application
{
    private WindowsUiService? _service;
    private MainViewModel? _viewModel;
    private int _errorDialogActive;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        WindowsUiRuntimeLog.Initialize();
        WindowsUiRuntimeLog.Write("STARTUP", "Application startup entered.");
        RegisterExceptionHandlers();

        // Do not let a service/configuration failure terminate the application before
        // WPF has an authoritative main window.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        Window window;
        try
        {
            window = new MainWindow();
            WindowsUiRuntimeLog.Write("STARTUP", "MainWindow created.");
        }
        catch (Exception ex)
        {
            WindowsUiErrorLog.Write("MainWindow construction failed.", ex);
            window = new Window
            {
                Title = "Zoom Auto Admit",
                Width = 720,
                Height = 420,
                Content = new System.Windows.Controls.TextBlock
                {
                    Text = "The main interface could not be loaded. See windows-ui.log for details.",
                    Margin = new Thickness(24),
                    TextWrapping = TextWrapping.Wrap
                }
            };
        }

        MainWindow = window;
        window.Show();
        WindowsUiRuntimeLog.Write("STARTUP", "MainWindow assigned and shown.");
        ShutdownMode = ShutdownMode.OnMainWindowClose;

        try
        {
            _service = new WindowsUiService(new WindowsRuntimeBootstrapper());
            WindowsUiRuntimeLog.Write("SERVICES", "Windows runtime services initialized.");
            _viewModel = new MainViewModel(_service);
            WindowsUiRuntimeLog.Write("VIEWMODELS", "Main view model graph created.");
            window.DataContext = _viewModel;
            await _viewModel.InitializeAsync();
            WindowsUiRuntimeLog.Write("VIEWMODELS", "View model initialization completed.");
        }
        catch (Exception ex)
        {
            ReportNonCriticalError(
                "Windows UI initialization failed. The application will remain open.",
                ex);
        }
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        try
        {
            _viewModel?.Dispose();
            if (_service != null) await _service.DisposeAsync();
        }
        catch (Exception ex) { WindowsUiErrorLog.Write("Application shutdown failed.", ex); }
        finally
        {
            UnregisterExceptionHandlers();
            WindowsUiRuntimeLog.Shutdown();
            base.OnExit(e);
        }
    }

    private void RegisterExceptionHandlers()
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private void UnregisterExceptionHandlers()
    {
        DispatcherUnhandledException -= OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException -= OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException -= OnUnobservedTaskException;
    }

    private void OnDispatcherUnhandledException(
        object sender,
        DispatcherUnhandledExceptionEventArgs e)
    {
        WindowsUiErrorLog.Write("Unhandled UI thread exception.", e.Exception);
        WindowsUiRuntimeLog.Write("EXCEPTION", e.Exception.ToString());
        e.Handled = true;
        ShowErrorDialog("An unexpected interface error occurred. The application will stay open.", e.Exception);
    }

    private void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception exception)
            WindowsUiErrorLog.Write("Unhandled application exception.", exception);
        if (e.ExceptionObject is Exception runtimeException)
            WindowsUiRuntimeLog.Write("EXCEPTION", runtimeException.ToString());
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        WindowsUiErrorLog.Write("Unobserved background task exception.", e.Exception);
        WindowsUiRuntimeLog.Write("EXCEPTION", e.Exception.ToString());
        e.SetObserved();
        Dispatcher.BeginInvoke(() =>
            ShowErrorDialog("A background service reported an error. The application will stay open.", e.Exception));
    }

    private void ReportNonCriticalError(string message, Exception exception)
    {
        WindowsUiErrorLog.Write(message, exception);
        WindowsUiRuntimeLog.Write("INITIALIZATION", $"{message} {exception}");
        ShowErrorDialog(message, exception);
    }

    private void ShowErrorDialog(string message, Exception exception)
    {
        if (Interlocked.Exchange(ref _errorDialogActive, 1) != 0) return;
        try
        {
            string detail = exception is AggregateException aggregate
                ? aggregate.Flatten().InnerExceptions[0].Message
                : exception.Message;
            MessageBox.Show(
                MainWindow,
                $"{message}{Environment.NewLine}{Environment.NewLine}{detail}{Environment.NewLine}{Environment.NewLine}Log: {WindowsUiErrorLog.FilePath}",
                "Zoom Auto Admit",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally { Interlocked.Exchange(ref _errorDialogActive, 0); }
    }
}
