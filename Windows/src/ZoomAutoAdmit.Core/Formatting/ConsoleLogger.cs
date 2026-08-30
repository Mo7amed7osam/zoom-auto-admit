namespace ZoomAutoAdmit.Core.Formatting;

public enum LogLevel
{
    Debug,
    Info,
    Success,
    Warn,
    Error
}

public static class ConsoleLogger
{
    private static readonly object LockObj = new();

    public static void Info(string message) => Log(LogLevel.Info, message);
    public static void Success(string message) => Log(LogLevel.Success, message);
    public static void Warn(string message) => Log(LogLevel.Warn, message);
    public static void Error(string message) => Log(LogLevel.Error, message);
    public static void Debug(string message) => Log(LogLevel.Debug, message);

    public static void Log(LogLevel level, string message)
    {
        var timestamp = DateTime.Now.ToString("HH:mm:ss.fff");
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

        lock (LockObj)
        {
            var prevColor = Console.ForegroundColor;
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write($"[{timestamp}] ");
            Console.ForegroundColor = color;
            Console.Write($"{prefix} ");
            Console.ForegroundColor = prevColor;
            Console.WriteLine(message);
        }
    }
}
