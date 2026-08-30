namespace ZoomAutoAdmit.WebAutomation.Browser;

public sealed record ZoomBrowserProfile(
    string Name,
    string DirectoryPath,
    string ReadyMarkerPath,
    bool HasReusableSession);

public sealed record ZoomBrowserLaunchPlan(
    ZoomBrowserProfile Profile,
    bool Headless);
