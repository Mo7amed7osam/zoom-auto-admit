using System.Text.RegularExpressions;

namespace ZoomAutoAdmit.WebAutomation.Browser;

public sealed class ZoomProfileManager
{
    private const string ReadyMarkerFileName = ".zoom-session-ready";
    private static readonly Regex SafeProfileNamePattern = new(
        @"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private readonly string _profilesRoot;

    public ZoomProfileManager(string? profilesRoot = null)
    {
        _profilesRoot = Path.GetFullPath(profilesRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ZoomAutoAdmit",
            "Profiles"));
    }

    public string ProfilesRoot => _profilesRoot;

    public ZoomBrowserProfile GetOrCreate(string requestedName)
    {
        string name = NormalizeAndValidateName(requestedName);
        Directory.CreateDirectory(_profilesRoot);
        string directory = Path.GetFullPath(Path.Combine(_profilesRoot, name));
        string rootWithSeparator = _profilesRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!directory.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Resolved browser profile escaped the managed Profiles directory.");
        Directory.CreateDirectory(directory);
        string marker = Path.Combine(directory, ReadyMarkerFileName);
        return new ZoomBrowserProfile(name, directory, marker, File.Exists(marker));
    }

    public ZoomBrowserProfile MarkSessionReady(ZoomBrowserProfile profile)
    {
        ValidateManagedProfile(profile);
        File.WriteAllText(profile.ReadyMarkerPath, "Zoom authenticated meeting session initialized.");
        return profile with { HasReusableSession = true };
    }

    public ZoomBrowserLaunchPlan CreateLaunchPlan(ZoomBrowserProfile profile, bool forceHeaded)
    {
        ValidateManagedProfile(profile);
        return new ZoomBrowserLaunchPlan(profile, Headless: profile.HasReusableSession && !forceHeaded);
    }

    private static string NormalizeAndValidateName(string requestedName)
    {
        string name = requestedName.Trim();
        if (name.Equals("default", StringComparison.OrdinalIgnoreCase)) name = "Default";
        if (!SafeProfileNamePattern.IsMatch(name))
            throw new ArgumentException(
                "Profile name must be 1-64 characters using letters, numbers, dot, underscore, or hyphen.",
                nameof(requestedName));
        return name;
    }

    private void ValidateManagedProfile(ZoomBrowserProfile profile)
    {
        string directory = Path.GetFullPath(profile.DirectoryPath);
        string rootWithSeparator = _profilesRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!directory.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Browser profile is outside the managed Profiles directory.");
    }
}
