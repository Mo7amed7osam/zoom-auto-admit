using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class PanelAdmissionVerifierTests
{
    [Fact]
    public void ParticipantAbsentForTwoCaptures_IsVerified()
    {
        var originalRow = Row("Ahmed", 240);
        var original = Panel([originalRow], 1);
        var verifier = new PanelAdmissionVerifier(originalRow, original);
        var empty = Panel([], 0);

        Assert.Equal(PanelAdmissionVerificationKind.Pending, verifier.Observe(empty).Kind);
        Assert.Equal(PanelAdmissionVerificationKind.Verified, verifier.Observe(empty).Kind);
    }

    [Fact]
    public void CountDecreasesAndOriginalRowDisappears_IsVerifiedAfterTwoCaptures()
    {
        var originalRow = Row("Ahmed", 240);
        var verifier = new PanelAdmissionVerifier(originalRow, Panel([originalRow, Row("Zeyad", 285)], 2));
        var after = Panel([Row("Zeyad", 285)], 1);

        Assert.Equal(PanelAdmissionVerificationKind.Pending, verifier.Observe(after).Kind);
        Assert.Equal(PanelAdmissionVerificationKind.Verified, verifier.Observe(after).Kind);
    }

    [Fact]
    public void HoverButtonDisappearanceWhileParticipantRemains_IsNeverVerification()
    {
        var row = Row("Ahmed", 240);
        var panel = Panel([row], 1);
        var verifier = new PanelAdmissionVerifier(row, panel);

        Assert.Equal(PanelAdmissionVerificationKind.Pending, verifier.Observe(panel).Kind);
        Assert.Equal(PanelAdmissionVerificationKind.Pending, verifier.Observe(panel).Kind);
    }

    private static WaitingParticipantRowCandidate Row(string name, double y) => new()
    {
        ParticipantName = name,
        RawText = name,
        TextBounds = new(1510, y, 100, 14),
        RowBounds = new(1485, y - 5, 425, 24),
        Confidence = 0.99
    };

    private static ParticipantsPanelDetectionResult Panel(
        IReadOnlyList<WaitingParticipantRowCandidate> rows,
        int count) => new()
    {
        IsPanelVisible = true,
        ParticipantsHeader = new("Participants", new(1500, 100, 100, 14), Array.Empty<OcrWord>()),
        WaitingRoomHeader = new($"Waiting room ({count})", new(1500, 200, 140, 14), Array.Empty<OcrWord>()),
        JoinedHeader = new("Joined", new(1500, 340, 60, 14), Array.Empty<OcrWord>()),
        DeclaredWaitingCount = count,
        PanelBounds = new(1480, 90, 440, 270),
        Rows = rows
    };
}
