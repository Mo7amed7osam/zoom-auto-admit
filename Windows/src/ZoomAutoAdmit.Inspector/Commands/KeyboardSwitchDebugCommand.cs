using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.WindowsRuntime;

namespace ZoomAutoAdmit.Inspector.Commands;

/// <summary>Opt-in diagnostic entry point for the same account switch used by the Accounts button.</summary>
public static class KeyboardSwitchDebugCommand
{
    public static int Execute(CliOptions options)
    {
        if (string.IsNullOrWhiteSpace(options.TargetEmail))
        {
            ConsoleLogger.Error("keyboard-switch-debug requires --target-email <exact-email>.");
            return 1;
        }
        using var cancel = new CancellationTokenSource();
        ConsoleCancelEventHandler handler = (_, e) => { e.Cancel = true; cancel.Cancel(); };
        Console.CancelKeyPress += handler;
        try
        {
            var result = new WindowsKeyboardAccountSwitcher()
                .SwitchAsync(options.TargetEmail, cancel.Token, options.TargetProcessId).GetAwaiter().GetResult();
            if (!result.IsSuccess) ConsoleLogger.Error(result.ErrorMessage ?? "Account switch failed.");
            return result.IsSuccess ? 0 : 1;
        }
        finally { Console.CancelKeyPress -= handler; }
    }
}
