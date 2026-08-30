namespace ZoomAutoAdmit.Core.Models;

public class CliOptions
{
    public string Command { get; set; } = "inspect";
    public bool CommandExplicitlySet { get; set; }
    public bool ShowAll { get; set; }
    public string? Query { get; set; }
    public int? TargetProcessId { get; set; }
    public int MaxDepth { get; set; } = 15;
    public int MaxElements { get; set; } = 800;
    public int DelaySeconds { get; set; } = 5;
    public int TimeoutSeconds { get; set; } = 20;
    public bool TimeoutExplicitlySet { get; set; }
    public bool ShowHelp { get; set; }
    public bool Debug { get; set; }
    public string Engine { get; set; } = "windows";
    public string WebProfile { get; set; } = "default";
    public string? MeetingUrl { get; set; }
    public bool WebHeaded { get; set; }
    public int WebPollIntervalMilliseconds { get; set; } = 750;

    private static readonly HashSet<string> KnownCommands = new(StringComparer.OrdinalIgnoreCase)
    {
        "inspect",
        "processes",
        "find",
        "account-menu-inspect",
        "account-menu-capture",
        "profile-menu-watch",
        "meeting-watch",
        "waiting-toast-watch",
        "toast-watch",
        "ocr-smoke",
        "waiting-toast-admit-once",
        "waiting-row-hover-watch",
        "waiting-room-auto-admit",
        "background-zoom-test"
    };

    public static CliOptions Parse(string[] args)
    {
        var options = new CliOptions();

        if (args.Length == 0)
        {
            return options;
        }

        int index = 0;

        while (index < args.Length)
        {
            var arg = args[index].Trim();
            string strippedArg = arg.TrimStart('-');

            if (arg.Equals("--help", StringComparison.OrdinalIgnoreCase) || 
                arg.Equals("-h", StringComparison.OrdinalIgnoreCase) || 
                arg.Equals("/?"))
            {
                options.ShowHelp = true;
            }
            else if (KnownCommands.Contains(strippedArg))
            {
                options.Command = strippedArg.ToLowerInvariant();
                options.CommandExplicitlySet = true;
            }
            else if (arg.Equals("--all", StringComparison.OrdinalIgnoreCase) || arg.Equals("-a", StringComparison.OrdinalIgnoreCase))
            {
                options.ShowAll = true;
                options.MaxDepth = 35;
                options.MaxElements = 3000;
            }
            else if (arg.Equals("--debug", StringComparison.OrdinalIgnoreCase))
            {
                options.Debug = true;
            }
            else if (arg.Equals("--engine", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length)
                {
                    options.Engine = args[++index].Trim().ToLowerInvariant();
                }
            }
            else if (arg.Equals("--profile", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length)
                {
                    options.WebProfile = args[++index].Trim();
                }
            }
            else if (arg.Equals("--meeting-url", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length)
                {
                    options.MeetingUrl = args[++index].Trim();
                    if (!options.CommandExplicitlySet)
                    {
                        options.Command = "waiting-room-auto-admit";
                    }
                }
            }
            else if (arg.Equals("--headed", StringComparison.OrdinalIgnoreCase))
            {
                options.WebHeaded = true;
            }
            else if (arg.Equals("--poll-ms", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out int pollMilliseconds))
                {
                    options.WebPollIntervalMilliseconds = Math.Clamp(pollMilliseconds, 500, 1000);
                    index++;
                }
            }
            else if (arg.Equals("--delay", StringComparison.OrdinalIgnoreCase) || arg.Equals("-w", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out var delay))
                {
                    options.DelaySeconds = delay;
                    index++;
                }
            }
            else if (arg.Equals("--timeout", StringComparison.OrdinalIgnoreCase) || arg.Equals("-t", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out var timeout))
                {
                    options.TimeoutSeconds = options.Command.Equals("waiting-room-auto-admit", StringComparison.OrdinalIgnoreCase)
                        ? Math.Clamp(timeout, 0, 86400)
                        : Math.Clamp(timeout, 5, 120);
                    options.TimeoutExplicitlySet = true;
                    index++;
                }
            }
            else if (arg.Equals("--max-depth", StringComparison.OrdinalIgnoreCase) || arg.Equals("-d", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out var depth))
                {
                    options.MaxDepth = depth;
                    index++;
                }
            }
            else if (arg.Equals("--max-elements", StringComparison.OrdinalIgnoreCase) || arg.Equals("-m", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out var maxElem))
                {
                    options.MaxElements = maxElem;
                    index++;
                }
            }
            else if (arg.Equals("--pid", StringComparison.OrdinalIgnoreCase) || arg.Equals("-p", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 < args.Length && int.TryParse(args[index + 1], out var pid))
                {
                    options.TargetProcessId = pid;
                    index++;
                }
            }
            else if (options.Command.Equals("find", StringComparison.OrdinalIgnoreCase) && options.Query == null && !arg.StartsWith("-", StringComparison.Ordinal))
            {
                options.Query = arg;
            }
            index++;
        }

        if (options.Command.Equals("waiting-room-auto-admit", StringComparison.OrdinalIgnoreCase) && !options.TimeoutExplicitlySet)
        {
            options.TimeoutSeconds = 0; // 0 = continuous until Ctrl+C
        }

        return options;
    }

    public InspectionOptions ToInspectionOptions() =>
        new()
        {
            MaxDepth = MaxDepth,
            MaxElements = MaxElements,
            IncludeAllDetails = ShowAll,
            SearchFilter = Query,
            TargetProcessId = TargetProcessId
        };
}
