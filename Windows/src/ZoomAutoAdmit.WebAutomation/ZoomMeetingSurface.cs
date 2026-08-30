using Microsoft.Playwright;

namespace ZoomAutoAdmit.WebAutomation;

public sealed record ZoomMeetingSurface(IPage Page, IFrame Frame);
