namespace ZoomAutoAdmit.Core.Formatting;

public enum LogLevel
{
    Debug,
    Info,
    Success,
    Warn,
    Error
}

public sealed record LogEntry(DateTimeOffset Timestamp, LogLevel Level, string Message);

public static class ConsoleLogger
{
    private static readonly object LockObj = new();
    private static readonly Queue<LogEntry> History = new();

    public static event Action<LogEntry>? EntryWritten;

    public static IReadOnlyList<LogEntry> GetRecentEntries()
    {
        lock (LockObj) return History.ToArray();
    }

    public static void Info(string message) => Log(LogLevel.Info, message);
    public static void Success(string message) => Log(LogLevel.Success, message);
    public static void Warn(string message) => Log(LogLevel.Warn, message);
    public static void Error(string message) => Log(LogLevel.Error, message);
    public static void Debug(string message) => Log(LogLevel.Debug, message);

    public static void Log(LogLevel level, string message)
    {
        var occurredAt = DateTimeOffset.Now;
        var timestamp = occurredAt.ToString("HH:mm:ss.fff");
        var prefix = level switch
        {
            LogLevel.Debug => "[DEBUG]",
            LogLevel.Info => "[INFO ]",
            LogLevel.Success => "[OK   ]",
            LogLevel.Warn => "[WARN ]",
            LogLevel.Error => "[ERROR]",
            _ => "[INFO ]"
        };

        var color = level switch
        {
            LogLevel.Debug => ConsoleColor.DarkGray,
            LogLevel.Info => ConsoleColor.Cyan,
            LogLevel.Success => ConsoleColor.Green,
            LogLevel.Warn => ConsoleColor.Yellow,
            LogLevel.Error => ConsoleColor.Red,
            _ => ConsoleColor.Gray
        };

        var entry = new LogEntry(occurredAt, level, message);
        lock (LockObj)
        {
            var prevColor = Console.ForegroundColor;
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write($"[{timestamp}] ");
            Console.ForegroundColor = color;
            Console.Write($"{prefix} ");
            Console.ForegroundColor = prevColor;
            Console.WriteLine(message);
            History.Enqueue(entry);
            while (History.Count > 1000) History.Dequeue();
        }

        foreach (Action<LogEntry> subscriber in EntryWritten?.GetInvocationList() ?? [])
        {
            try { subscriber(entry); }
            catch { /* Logging observers must never interrupt meeting execution. */ }
        }
    }
}
