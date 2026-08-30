using ZoomAutoAdmit.Core.Formatting;
using ZoomAutoAdmit.Core.Models;
using ZoomAutoAdmit.Inspector.Commands;
using ZoomAutoAdmit.Inspector.Engines;

namespace ZoomAutoAdmit.Inspector;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var options = CliOptions.Parse(args);

        if (options.ShowHelp)
        {
            PrintUsage();
            return 0;
        }

        try
        {
            return options.Command.ToLowerInvariant() switch
            {
                "inspect" => InspectCommand.Execute(options),
                "processes" => ProcessesCommand.Execute(),
                "find" => FindCommand.Execute(options),
                "account-menu-inspect" => AccountMenuInspectCommand.Execute(options),
                "account-menu-capture" => AccountMenuCaptureCommand.Execute(options),
                "profile-menu-watch" => ProfileMenuWatchCommand.Execute(options),
                "meeting-watch" => MeetingWatchCommand.Execute(options),
                "waiting-toast-watch" or "toast-watch" => WaitingToastWatchCommand.Execute(options),
                "ocr-smoke" => OcrSmokeCommand.Execute(),
                "waiting-toast-admit-once" => WaitingToastAdmitOnceCommand.Execute(options),
                "waiting-row-hover-watch" => WaitingRowHoverWatchCommand.Execute(options),
                "waiting-room-auto-admit" => await AutoAdmitEngineFactory
                    .Create(options.Engine)
                    .RunAsync(options),
                "background-zoom-test" => BackgroundZoomTestCommand.Execute(options),
                _ => HandleUnknownCommand(options.Command)
            };
        }
        catch (Exception ex)
        {
            ConsoleLogger.Error($"Fatal error executing command '{options.Command}': {ex.Message}");
            ConsoleLogger.Debug(ex.ToString());
            return 1;
        }
    }

    private static int HandleUnknownCommand(string command)
    {
        ConsoleLogger.Error($"Unknown command '{command}'.");
        PrintUsage();
        return 1;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("================================================================================");
        Console.WriteLine("                    Zoom Auto Admit (Windows 11 / .NET 8)                       ");
        Console.WriteLine("================================================================================");
        Console.WriteLine("Usage:");
        Console.WriteLine("  dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- <command> [options]");
        Console.WriteLine("  .\\run-auto-admit.ps1 [command] [options]");
        Console.WriteLine();
        Console.WriteLine("Primary Commands:");
        Console.WriteLine("  waiting-room-auto-admit   Continuously auto-admit participants (Windows UI or Web engine)");
        Console.WriteLine("  background-zoom-test      Safe diagnostic probe of background window capture & input");
        Console.WriteLine("  inspect                   Print the Zoom UI Automation element tree (read-only)");
        Console.WriteLine("  processes                 Enumerate candidate Zoom processes and window handles");
        Console.WriteLine("  find \"<search-term>\"      Search Zoom UIA tree by Name, AutomationId, ClassName");
        Console.WriteLine("  meeting-watch             Diagnostic watcher for meeting window & Waiting Room");
        Console.WriteLine("  waiting-toast-watch       Native Windows OCR diagnostic for Waiting Room toasts");
        Console.WriteLine("  waiting-row-hover-watch   READ-ONLY: verify Participants panel individual Admit hover");
        Console.WriteLine();
        Console.WriteLine("Options & Default Values:");
        Console.WriteLine("  --engine <windows|web>    Auto-admit engine to use (default: windows)");
        Console.WriteLine("  --meeting-url <URL>       HTTPS Zoom meeting URL (required when engine is web)");
        Console.WriteLine("  --profile <NAME>          Managed Chromium profile folder (default: default)");
        Console.WriteLine("  --poll-ms <N>             Poll interval in milliseconds, 500-1000ms (default: 750)");
        Console.WriteLine("  --headed                  Launch visible browser for login/refresh (default: headless)");
        Console.WriteLine("  --timeout, -t <N>         Watch duration in seconds (default: 0 = continuous until Ctrl+C)");
        Console.WriteLine("  --debug                   Enable verbose OCR diagnostics");
        Console.WriteLine("  --help, -h                Show this help message");
        Console.WriteLine();
        Console.WriteLine("Examples:");
        Console.WriteLine("  1. Standard Background Windows Auto-Admit:");
        Console.WriteLine("     dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- waiting-room-auto-admit");
        Console.WriteLine();
        Console.WriteLine("  2. Web-Engine Auto-Admit:");
        Console.WriteLine("     dotnet run --project Windows/src/ZoomAutoAdmit.Inspector/ZoomAutoAdmit.Inspector.csproj -- waiting-room-auto-admit --engine web --meeting-url \"https://zoom.us/j/91473108490\"");
        Console.WriteLine();
        Console.WriteLine("  3. Using the PowerShell Launcher:");
        Console.WriteLine("     .\\run-auto-admit.ps1 --meeting-url \"https://zoom.us/j/91473108490\" --profile test1");
        Console.WriteLine("================================================================================");
    }
}
