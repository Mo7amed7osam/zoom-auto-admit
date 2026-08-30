using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class WaitingRoomNotificationDetectorTests
{
    [Theory]
    [InlineData("Ahmed ragab")]
    [InlineData("Zeyad Tamer")]
    public void Detect_WindowsNotificationSplitAfterWaiting_ReturnsHighConfidenceCandidate(string participant)
    {
        var fixture = BuildNotification(participant, 1540, 900);

        var result = WaitingRoomToastDetector.Detect(ToOcr(fixture));

        var candidate = Assert.Single(result.AllCandidates.Where(item => item.IsAccepted));
        Assert.Equal($"{participant} entered the waiting", candidate.ParticipantRawText);
        Assert.Equal(participant, candidate.ParticipantNormalizedName);
        Assert.Equal(WaitingRoomNotificationLayout.WindowsNotification, candidate.LayoutType);
        Assert.Equal(0.99, candidate.Confidence, precision: 2);
        Assert.Equal(fixture.Admit.Bounds, candidate.AdmitBounds);
        Assert.Equal(fixture.View.Bounds, candidate.ViewBounds);
    }

    [Fact]
    public void Detect_UnrelatedViewsAndAdmitElsewhere_DoNotInterfereWithLocalPairing()
    {
        var real = BuildNotification("Ahmed ragab", 1540, 900);
        var terminalAdmit = new OcrWord("Admit", new(120, 310, 37, 12));
        var terminalView1 = new OcrWord("View", new(200, 250, 30, 12));
        var terminalView2 = new OcrWord("View", new(215, 310, 30, 12));
        var browserView = new OcrWord("View", new(800, 450, 30, 12));
        var noiseLines = new List<OcrLine>
        {
            Line("View", terminalView1),
            Line("Admit View", terminalAdmit, terminalView2),
            MakeLine("Waiting room", 120, 280),
            Line("View", browserView)
        };

        var result = WaitingRoomToastDetector.Detect(ToOcr(real, noiseLines));

        var candidate = Assert.Single(result.AllCandidates.Where(item => item.IsAccepted));
        Assert.Equal("Ahmed ragab", candidate.ParticipantNormalizedName);
        Assert.Equal(real.View.Bounds, candidate.ViewBounds);
        Assert.Equal(2, result.AllCandidates.Count);
        Assert.Equal(4, result.AllViewWordsFound.Count);
    }

    [Fact]
    public void Detect_TwoSimultaneousRealNotifications_ReturnsTwoIndependentCandidates()
    {
        var ahmed = BuildNotification("Ahmed ragab", 1450, 720);
        var zeyad = BuildNotification("Zeyad Tamer", 1450, 900);

        var result = WaitingRoomToastDetector.Detect(ToOcr(ahmed, zeyad.Lines));

        var accepted = result.AllCandidates.Where(item => item.IsAccepted).ToList();
        Assert.Equal(2, accepted.Count);
        Assert.Equal(new[] { "Ahmed ragab", "Zeyad Tamer" }, accepted.Select(item => item.ParticipantNormalizedName).OrderBy(name => name));
        Assert.All(accepted, item => Assert.Equal(WaitingRoomNotificationLayout.WindowsNotification, item.LayoutType));
    }

    [Fact]
    public void Detect_HeaderNearButNotHorizontallyOverlappingButtonRow_IsRejected()
    {
        var header = MakeLine("Ahmed entered the waiting room", 100, 900);
        var admit = new OcrWord("Admit", new(500, 970, 37, 10));
        var view = new OcrWord("View", new(650, 970, 29, 10));
        var lines = new[] { header, Line("Admit View", admit, view) };

        var result = WaitingRoomToastDetector.Detect(
            new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080)));

        Assert.False(result.IsDetected);
        Assert.False(Assert.Single(result.AllCandidates).IsAccepted);
    }

    private static NotificationFixture BuildNotification(string participant, double x, double y)
    {
        var first = MakeLine($"{participant} entered the waiting", x, y);
        var second = MakeLine("room", x, y + 22);
        var admit = new OcrWord("Admit", new(x, y + 70, 37, 10));
        var view = new OcrWord("View", new(x + 173, y + 70, 29, 10));
        return new NotificationFixture(new[] { first, second, Line("Admit View", admit, view) }, admit, view);
    }

    private static OcrLine MakeLine(string text, double x, double y)
    {
        double cursor = x;
        var words = text.Split(' ').Select(value =>
        {
            double width = Math.Max(24, value.Length * 7);
            var word = new OcrWord(value, new(cursor, y, width, 14));
            cursor += width + 6;
            return word;
        }).ToList();
        return new OcrLine(text, new(x, y, cursor - x - 6, 14), words);
    }

    private static OcrLine Line(string text, params OcrWord[] words)
    {
        double left = words.Min(word => word.Bounds.X);
        double top = words.Min(word => word.Bounds.Y);
        double right = words.Max(word => word.Bounds.X + word.Bounds.Width);
        double bottom = words.Max(word => word.Bounds.Y + word.Bounds.Height);
        return new OcrLine(text, new(left, top, right - left, bottom - top), words);
    }

    private static OcrResult ToOcr(NotificationFixture fixture, IEnumerable<OcrLine>? extra = null)
    {
        var lines = fixture.Lines.Concat(extra ?? Array.Empty<OcrLine>()).ToList();
        return new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080));
    }

    private sealed record NotificationFixture(IReadOnlyList<OcrLine> Lines, OcrWord Admit, OcrWord View);
}
