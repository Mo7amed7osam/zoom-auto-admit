using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class WaitingRoomParticipantRowDetectorTests
{
    [Fact]
    public void DetectsParticipantsWaitingRoomAndJoinedHeaders()
    {
        var result = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));

        Assert.True(result.IsPanelVisible);
        Assert.Equal("Participants", result.ParticipantsHeader!.Text);
        Assert.Equal("Waiting room (1)", result.WaitingRoomHeader!.Text);
        Assert.Equal("Joined (2)", result.JoinedHeader!.Text);
    }

    [Fact]
    public void DetectsOneWaitingParticipantWithoutRequiringAdmitBeforeHover()
    {
        var ocr = PanelOcr([("eyouth Coordinator (Guest)", 240)]);

        var result = WaitingRoomParticipantRowDetector.Detect(ocr);

        var row = Assert.Single(result.Rows);
        Assert.Equal("eyouth Coordinator", row.ParticipantName);
        Assert.DoesNotContain(ocr.Words, word => word.Text.Equals("Admit", StringComparison.OrdinalIgnoreCase));
        Assert.True(row.Confidence >= 0.90);
    }

    [Fact]
    public void GuestMarkerEndsIdentityAndExcludesFollowingStatusFromBounds()
    {
        var ocr = PanelOcr([("mohab mohamed (Guest) We've let them know you're here.", 240)]);

        var row = Assert.Single(WaitingRoomParticipantRowDetector.Detect(ocr).Rows);
        var guest = Assert.Single(ocr.Words.Where(word => word.Text.Equals("(Guest)", StringComparison.OrdinalIgnoreCase)));
        var status = Assert.Single(ocr.Words.Where(word => word.Text.Equals("We've", StringComparison.OrdinalIgnoreCase)));

        Assert.Equal("mohab mohamed", row.ParticipantName);
        Assert.Equal("mohab mohamed", row.RawText);
        Assert.True(row.TextBounds.X + row.TextBounds.Width < guest.Bounds.X);
        Assert.True(row.TextBounds.X + row.TextBounds.Width < status.Bounds.X);
        Assert.True(row.SafeHoverPoint.X <= row.TextBounds.X + row.TextBounds.Width);
    }

    [Fact]
    public void DetectsMultipleWaitingParticipantsInTopToBottomOrder()
    {
        var result = WaitingRoomParticipantRowDetector.Detect(PanelOcr([
            ("Participant A (Guest)", 235),
            ("Participant B (Guest)", 275),
            ("Participant C (Guest)", 315)
        ], joinedY: 360));

        Assert.Equal(3, result.Rows.Count);
        Assert.Equal(["Participant A", "Participant B", "Participant C"], result.Rows.Select(row => row.ParticipantName));
        Assert.True(result.Rows[0].RowBounds.Y < result.Rows[1].RowBounds.Y);
    }

    [Fact]
    public void RowGeometryAndHoverPointStayInsideNameSideOfRow()
    {
        var row = Assert.Single(WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice Example (Guest)", 240)])).Rows);

        Assert.True(Contains(row.RowBounds, row.SafeHoverPoint));
        Assert.True(row.SafeHoverPoint.X < row.RowBounds.X + row.RowBounds.Width * 0.60);
        Assert.InRange(row.SafeHoverPoint.Y, row.TextBounds.Y, row.TextBounds.Y + row.TextBounds.Height);
    }

    [Fact]
    public void ExactAdmitAppearingInsideSameRowAfterHoverIsConfirmed()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var originalRow = Assert.Single(before.Rows);
        var afterOcr = PanelOcr([("Alice (Guest) Admit ...", 240)]);

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(originalRow, before, afterOcr);

        Assert.True(result.IsConfirmed);
        Assert.Equal("Admit", result.AdmitWord!.Text);
        Assert.Equal("Alice", result.Row!.ParticipantName);
        Assert.Equal(result.AdmitWord.Center, result.AdmitCenter);
    }

    [Fact]
    public void AdmitAllIsRejected()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var originalRow = Assert.Single(before.Rows);
        var afterOcr = PanelOcr([("Alice (Guest) Admit all", 240)]);

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(originalRow, before, afterOcr);

        Assert.False(result.IsConfirmed);
        Assert.Contains(result.RejectionReasons, reason => reason.Contains("Admit All", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ToastAdmitOutsideWaitingRowIsRejected()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var originalRow = Assert.Single(before.Rows);
        var after = PanelOcr([("Alice (Guest)", 240)]);
        after = AddLine(after, Line("Admit View", 1610, 900, ("Admit", 1610), ("View", 1780)));

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(originalRow, before, after);

        Assert.False(result.IsConfirmed);
    }

    [Fact]
    public void AdmitFromDifferentParticipantRowIsRejected()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([
            ("Alice (Guest)", 240),
            ("Bob (Guest)", 285)
        ]));
        var originalRow = before.Rows.First();
        var after = PanelOcr([
            ("Alice (Guest)", 240),
            ("Bob (Guest) Admit ...", 285)
        ]);

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(originalRow, before, after);

        Assert.False(result.IsConfirmed);
        Assert.Contains(result.RejectionReasons, reason => reason.Contains("another row", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ChangedParticipantTextAfterHover_DoesNotInvalidateTrustedOriginalRow()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var originalRow = Assert.Single(before.Rows);
        var after = PanelOcr([("Different hover state Admit ...", 240)]);

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(originalRow, before, after);

        Assert.True(result.IsConfirmed);
        Assert.Equal(originalRow, result.Row);
        Assert.Equal("Admit", result.AdmitWord!.Text);
    }

    [Fact]
    public void MissingParticipantTextAfterHover_WithAdmitInOriginalGeometry_IsAccepted()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var original = Assert.Single(before.Rows);
        var after = PanelOcr(Array.Empty<(string Text, int Y)>());
        after = AddLine(after, Line("Admit", 1750, 240, ("Admit", 1750)));

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(original, before, after);

        Assert.True(result.IsConfirmed);
    }

    [Fact]
    public void HoverReflowAdmitMayReplacePreHoverNameSuffixAndIsStillAccepted()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(
            PanelOcr([("Mohab Mohamed _Coordinator_Long (Guest)", 240)]));
        var original = Assert.Single(before.Rows);
        double actionX = original.RowBounds.X + original.RowBounds.Width * 0.60;
        Assert.True(actionX < original.TextBounds.X + original.TextBounds.Width);
        var admit = new OcrWord("Admit", new(actionX, 240, 45, 14));
        var after = AddLine(
            PanelOcr(Array.Empty<(string Text, int Y)>()),
            new OcrLine("Admit", admit.Bounds, [admit]));

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(original, before, after);

        Assert.True(result.IsConfirmed);
        Assert.Equal(admit.Bounds, result.AdmitWord!.Bounds);
    }

    [Fact]
    public void AdmitMovedTenPixelsBelowOriginalRow_IsAcceptedWithinExpandedTolerance()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var original = Assert.Single(before.Rows);
        double admitY = original.RowBounds.Y + original.RowBounds.Height + 5;
        var admit = new OcrWord("Admit", new(1750, admitY, 37, 10));
        var after = AddLine(PanelOcr(Array.Empty<(string Text, int Y)>()), new OcrLine("Admit", admit.Bounds, [admit]));

        var result = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(original, before, after);

        Assert.True(result.IsConfirmed);
    }

    [Fact]
    public void FullScreenOcrMissingAdmit_ButTrustedRowCropAdmit_IsAccepted()
    {
        var before = WaitingRoomParticipantRowDetector.Detect(PanelOcr([("Alice (Guest)", 240)]));
        var original = Assert.Single(before.Rows);
        var full = PanelOcr([("Alice (Guest)", 240)]);
        Assert.False(WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(original, before, full).IsConfirmed);
        var admit = new OcrWord("Admit", new(1750, 240, 37, 10));
        var crop = new OcrResult([new OcrLine("Admit", admit.Bounds, [admit])], [admit], new(1480, 220, 440, 60));

        var cropResult = WaitingRoomParticipantRowDetector.ValidateIndividualAdmitAfterHover(original, before, crop);

        Assert.True(cropResult.IsConfirmed);
        Assert.Equal(admit.Bounds, cropResult.AdmitWord!.Bounds);
    }

    [Fact]
    public void MissingPanelHeadersMeansPanelNotVisible()
    {
        var ocr = new OcrResult(
            [Line("Chrome page text", 100, 100, ("Chrome", 100), ("page", 160), ("text", 210))],
            Array.Empty<OcrWord>(),
            new(0, 0, 1920, 1080));

        var result = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.False(result.IsPanelVisible);
    }

    [Fact]
    public void FloatingPoppedOutPanel_OnLeftSide_IsAccepted()
    {
        var lines = new[]
        {
            Line("zm Participants (1)", 100, 100, ("zm", 100), ("Participants", 130), ("(1)", 230)),
            Line("Waiting room (2) Message Admit all", 100, 200, ("Waiting", 100), ("room", 160), ("(2)", 210), ("Message", 250), ("Admit", 320), ("all", 360)),
            Line("Mohab Mohamed (Guest)", 100, 240, ("Mohab", 100), ("Mohamed", 150), ("(Guest)", 220)),
            Line("Joined (1)", 100, 340, ("Joined", 100), ("(1)", 160))
        };
        var ocr = CreateOcr(lines);

        var result = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.True(result.IsPanelVisible);
        Assert.Equal(2, result.DeclaredWaitingCount);
        Assert.Single(result.Rows);
        Assert.Equal("Mohab Mohamed", result.Rows[0].ParticipantName);
    }

    [Fact]
    public void JoinedHeaderFormsLowerBoundaryForRows()
    {
        var ocr = PanelOcr([("Alice (Guest)", 240)]);
        ocr = AddLine(ocr, Line("Not a waiting participant", 1510, 400, ("Not", 1510), ("participant", 1550)));

        var result = WaitingRoomParticipantRowDetector.Detect(ocr);

        Assert.Single(result.Rows);
        Assert.Equal("Alice", result.Rows[0].ParticipantName);
    }

    private static OcrResult PanelOcr((string Text, int Y)[] rows, int joinedY = 340)
    {
        var lines = new List<OcrLine>
        {
            Line("Participants", 1500, 100, ("Participants", 1500)),
            Line($"Waiting room ({rows.Length})", 1500, 200, ("Waiting", 1500), ("room", 1560), ($"({rows.Length})", 1610))
        };
        foreach (var row in rows)
        {
            lines.Add(RowLine(row.Text, row.Y));
        }
        lines.Add(Line("Joined (2)", 1500, joinedY, ("Joined", 1500), ("(2)", 1560)));
        return CreateOcr(lines);
    }

    private static OcrLine RowLine(string text, int y)
    {
        var tokens = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var words = new List<OcrWord>();
        int x = 1510;
        foreach (var token in tokens)
        {
            int width = token switch
            {
                "Admit" => 37,
                "all" => 20,
                "..." => 20,
                _ => Math.Max(25, token.Length * 8)
            };
            words.Add(new OcrWord(token, new(x, y, width, 14)));
            x += width + (token == "(Guest)" ? 100 : 8);
        }
        return new OcrLine(text, Union(words.Select(word => word.Bounds)), words);
    }

    private static OcrLine Line(string text, int x, int y, params (string Text, int X)[] tokens)
    {
        var words = tokens.Select(token => new OcrWord(token.Text, new(token.X, y, Math.Max(20, token.Text.Length * 8), 14))).ToList();
        return new OcrLine(text, new(x, y, Math.Max(40, words.Max(word => word.Bounds.X + word.Bounds.Width) - x), 14), words);
    }

    private static OcrResult AddLine(OcrResult source, OcrLine line)
    {
        var lines = source.Lines.Append(line).ToList();
        return new OcrResult(lines, lines.SelectMany(item => item.Words).ToList(), source.ImageBounds);
    }

    private static OcrResult CreateOcr(IEnumerable<OcrLine> lines)
    {
        var list = lines.ToList();
        return new OcrResult(list, list.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080));
    }

    private static BoundingRectangleInfo Union(IEnumerable<BoundingRectangleInfo> values)
    {
        var list = values.ToList();
        double left = list.Min(value => value.X);
        double top = list.Min(value => value.Y);
        double right = list.Max(value => value.X + value.Width);
        double bottom = list.Max(value => value.Y + value.Height);
        return new(left, top, right - left, bottom - top);
    }

    private static bool Contains(BoundingRectangleInfo bounds, (double X, double Y) point) =>
        point.X >= bounds.X && point.X <= bounds.X + bounds.Width &&
        point.Y >= bounds.Y && point.Y <= bounds.Y + bounds.Height;
}
