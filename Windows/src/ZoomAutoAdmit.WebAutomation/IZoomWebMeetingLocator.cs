using Microsoft.Playwright;

namespace ZoomAutoAdmit.WebAutomation;

public interface IZoomWebMeetingLocator
{
    Task<ZoomMeetingSurface?> FindAsync(IBrowserContext context);
    Task<ZoomMeetingSurface?> FindAsync(IPage page);
}
