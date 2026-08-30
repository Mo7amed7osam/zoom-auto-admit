using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class WaitingRoomToastDetectorTests
{
    [Fact]
    public void Detect_ExactLiveMohabMohamedTopCenterToast_IsInMeetingHighConfidence()
    {
        var header = new OcrLine(
            "mohab mohamed entered the waiting room",
            new(720, 140, 300, 14),
            new List<OcrWord>
            {
                new("mohab", new(720, 140, 42, 14)),
                new("mohamed", new(768, 140, 58, 14)),
                new("entered", new(832, 140, 50, 14)),
                new("the", new(888, 140, 22, 14)),
                new("waiting", new(916, 140, 48, 14)),
                new("room", new(970, 140, 35, 14))
            });
        var admit = new OcrWord("Admit", new(760, 190, 37, 10));
        var view = new OcrWord("View", new(940, 190, 29, 10));
        var buttons = new OcrLine("Admit View", new(760, 190, 209, 10), new List<OcrWord> { admit, view });
        var sharedContent = new OcrLine("UiPath Studio PowerPoint browser share", new(200, 500, 450, 16),
            new List<OcrWord> { new("UiPath", new(200, 500, 50, 16)), new("PowerPoint", new(300, 500, 80, 16)) });
        var lines = new[] { header, buttons, sharedContent };

        var result = WaitingRoomToastDetector.Detect(
            new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080)));

        var candidate = Assert.Single(result.AllCandidates.Where(item => item.IsAccepted));
        Assert.Equal("mohab mohamed", candidate.ParticipantNormalizedName);
        Assert.Equal(WaitingRoomNotificationLayout.InMeetingToast, candidate.LayoutType);
        Assert.True(candidate.Confidence >= 0.95);
    }

    [Fact]
    public void Detect_InMeetingToastAtTopCenterOverPowerPointContent_IsAcceptedWithoutFixedLocation()
    {
        var background = new OcrLine(
            "PowerPoint Quarterly Results Revenue View",
            new BoundingRectangleInfo(200, 300, 500, 18),
            new List<OcrWord>
            {
                new("PowerPoint", new(200, 300, 80, 18)),
                new("View", new(650, 300, 35, 18))
            });
        var headerWords = new List<OcrWord>
        {
            new("Mohab", new(760, 120, 45, 14)),
            new("Mohamed", new(810, 120, 60, 14)),
            new("_Coordinator", new(875, 120, 90, 14)),
            new("entered", new(970, 120, 50, 14)),
            new("the", new(1025, 120, 22, 14)),
            new("waiting", new(1052, 120, 48, 14)),
            new("room", new(1105, 120, 35, 14))
        };
        var header = new OcrLine(
            "Mohab Mohamed _Coordinator entered the waiting room",
            new(760, 120, 380, 14),
            headerWords);
        var admit = new OcrWord("Admit", new(800, 170, 37, 10));
        var view = new OcrWord("View", new(980, 170, 29, 10));
        var buttons = new OcrLine("Admit View", new(800, 170, 209, 10), new List<OcrWord> { admit, view });
        var lines = new[] { background, header, buttons };

        var result = WaitingRoomToastDetector.Detect(
            new OcrResult(lines, lines.SelectMany(line => line.Words).ToList(), new(0, 0, 1920, 1080)));

        var candidate = Assert.Single(result.AllCandidates.Where(item => item.IsAccepted));
        Assert.Equal("Mohab Mohamed _Coordinator", candidate.ParticipantNormalizedName);
        Assert.Equal(WaitingRoomNotificationLayout.InMeetingToast, candidate.LayoutType);
        Assert.Equal(0.99, candidate.Confidence, precision: 2);
        Assert.Equal(admit.Bounds, candidate.AdmitBounds);
    }

    [Fact]
    public void Detect_WithRealRuntimeEvidence_CorrectlyLocalizesToastAndAdmitCenter()
    {
        // Real runtime evidence from user prompt:
        // Participant: eyouth Coordinator
        // Toast bounds: X=1615, Y=917, W=456, H=88
        // Admit OCR box: X=1617, Y=984, W=37, H=10
        // View OCR box: X=1790, Y=984, W=29, H=10
        // Expected Admit center: (1635.5, 989)

        var headerWords = new List<OcrWord>
        {
            new("eyouth", new BoundingRectangleInfo(1617, 930, 45, 14)),
            new("Coordinator", new BoundingRectangleInfo(1665, 930, 80, 14)),
            new("entered", new BoundingRectangleInfo(1750, 930, 50, 14)),
            new("the", new BoundingRectangleInfo(1805, 930, 20, 14)),
            new("waiting", new BoundingRectangleInfo(1830, 930, 45, 14)),
            new("room", new BoundingRectangleInfo(1880, 930, 35, 14))
        };
        var headerLine = new OcrLine(
            "eyouth Coordinator entered the waiting room",
            new BoundingRectangleInfo(1617, 930, 300, 14),
            headerWords);

        var admitWord = new OcrWord("Admit", new BoundingRectangleInfo(1617, 984, 37, 10));
        var viewWord = new OcrWord("View", new BoundingRectangleInfo(1790, 984, 29, 10));
        var buttonLine = new OcrLine(
            "Admit View",
            new BoundingRectangleInfo(1617, 984, 202, 10),
            new List<OcrWord> { admitWord, viewWord });

        var allWords = new List<OcrWord>(headerWords) { admitWord, viewWord };
        var allLines = new List<OcrLine> { headerLine, buttonLine };
        var ocrResult = new OcrResult(allLines, allWords, new BoundingRectangleInfo(0, 0, 1920, 1080));

        var result = WaitingRoomToastDetector.Detect(ocrResult);

        Assert.True(result.IsDetected);
        Assert.NotNull(result.BestCandidate);
        Assert.Equal("eyouth Coordinator", result.BestCandidate.ParticipantName);
        Assert.Equal(1635.5, result.BestCandidate.AdmitCenter.X, precision: 1);
        Assert.Equal(989.0, result.BestCandidate.AdmitCenter.Y, precision: 1);
        Assert.True(result.BestCandidate.Confidence >= 0.95);
        Assert.True(result.BestCandidate.IsAccepted);
        Assert.Empty(result.BestCandidate.RejectionReasons);
        Assert.NotEmpty(result.BestCandidate.AcceptanceReasons);
    }

    [Fact]
    public void Detect_WithMultiLineToast_ExtractsParticipantNameFromPreviousLine()
    {
        var nameLine = new OcrLine(
            "John Doe",
            new BoundingRectangleInfo(1600, 915, 80, 15),
            new List<OcrWord> { new("John", new BoundingRectangleInfo(1600, 915, 35, 15)), new("Doe", new BoundingRectangleInfo(1640, 915, 40, 15)) });

        var headerLine = new OcrLine(
            "entered the waiting room",
            new BoundingRectangleInfo(1600, 935, 180, 15),
            new List<OcrWord> { new("entered", new BoundingRectangleInfo(1600, 935, 50, 15)), new("the", new BoundingRectangleInfo(1655, 935, 20, 15)), new("waiting", new BoundingRectangleInfo(1680, 935, 45, 15)), new("room", new BoundingRectangleInfo(1730, 935, 35, 15)) });

        var admitWord = new OcrWord("Admit", new BoundingRectangleInfo(1600, 970, 40, 12));
        var viewWord = new OcrWord("View", new BoundingRectangleInfo(1720, 970, 30, 12));
        var buttonLine = new OcrLine("Admit View", new BoundingRectangleInfo(1600, 970, 150, 12), new List<OcrWord> { admitWord, viewWord });

        var allLines = new List<OcrLine> { nameLine, headerLine, buttonLine };
        var allWords = nameLine.Words.Concat(headerLine.Words).Concat(buttonLine.Words).ToList();
        var ocrResult = new OcrResult(allLines, allWords, new BoundingRectangleInfo(0, 0, 1920, 1080));

        var result = WaitingRoomToastDetector.Detect(ocrResult);

        Assert.True(result.IsDetected);
        Assert.NotNull(result.BestCandidate);
        Assert.Equal("John Doe", result.BestCandidate.ParticipantName);
        Assert.Equal(1620.0, result.BestCandidate.AdmitCenter.X, precision: 1);
        Assert.Equal(976.0, result.BestCandidate.AdmitCenter.Y, precision: 1);
    }

    [Fact]
    public void Detect_WithExactLiveSplitOcr_AcceptsCandidateAndNormalizesAfterDetection()
    {
        var firstLine = new OcrLine(
            "eyouth Coordinator entered the",
            new BoundingRectangleInfo(1618, 917, 231, 16),
            new List<OcrWord>
            {
                new("eyouth", new(1618, 917, 51, 16)),
                new("Coordinator", new(1672, 917, 89, 12)),
                new("entered", new(1765, 917, 56, 12)),
                new("the", new(1826, 917, 23, 12))
            });
        var waitingLine = new OcrLine(
            "waiting room",
            new BoundingRectangleInfo(1618, 939, 97, 16),
            new List<OcrWord>
            {
                new("waiting", new(1618, 939, 52, 16)),
                new("room", new(1676, 943, 39, 8))
            });
        var admit = new OcrWord("Admit", new(1617, 984, 37, 10));
        var view = new OcrWord("View", new(1790, 984, 29, 10));
        var buttons = new OcrLine("Admit View", new(1617, 984, 202, 10), new List<OcrWord> { admit, view });
        var lines = new List<OcrLine> { firstLine, waitingLine, buttons };
        var words = lines.SelectMany(line => line.Words).ToList();

        var result = WaitingRoomToastDetector.Detect(new OcrResult(lines, words, new(0, 0, 1920, 1080)));

        Assert.True(result.IsDetected);
        Assert.NotNull(result.BestCandidate);
        Assert.Equal("eyouth Coordinator entered the", result.BestCandidate.ParticipantName);
        Assert.Equal(0.99, result.BestCandidate.Confidence, precision: 2);
        Assert.Equal(new BoundingRectangleInfo(1602, 924, 247, 85), result.BestCandidate.ToastBounds);
        Assert.Equal(new BoundingRectangleInfo(1617, 984, 37, 10), result.BestCandidate.AdmitWord!.Bounds);
        Assert.Equal(new BoundingRectangleInfo(1790, 984, 29, 10), result.BestCandidate.ViewWord!.Bounds);

        var identity = WaitingRoomParticipantIdentity.FromAcceptedCandidateText(result.BestCandidate.ParticipantName);
        Assert.Equal("eyouth Coordinator entered the", identity.RawText);
        Assert.Equal("eyouth Coordinator", identity.NormalizedName);

        var gate = new AdmitOnceSafetyGate();
        var frame1 = gate.ObserveConfirmationFrame(
            result.AllCandidates,
            new BoundingRectangleInfo(0, 0, 1920, 1080),
            DateTimeOffset.UtcNow);
        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted, frame1.Kind);
    }

    [Fact]
    public void ParticipantNormalizationCannotRemoveAlreadyAcceptedCandidate()
    {
        var admitBounds = new BoundingRectangleInfo(1617, 984, 37, 10);
        var candidate = new WaitingRoomToastCandidate
        {
            ParticipantName = "eyouth Coordinator entered the",
            HeaderLine = new OcrLine("waiting room", new(1618, 939, 97, 16), Array.Empty<OcrWord>()),
            AdmitWord = new OcrWord("Admit", admitBounds),
            ViewWord = new OcrWord("View", new(1790, 984, 29, 10)),
            AdmitCenter = (1635.5, 989),
            ToastBounds = new(1602, 924, 247, 85),
            Confidence = 0.99,
            IsAccepted = true
        };

        var identity = WaitingRoomParticipantIdentity.FromAcceptedCandidateText(candidate.ParticipantName);
        var gate = new AdmitOnceSafetyGate();
        var result = gate.ObserveConfirmationFrame([candidate], new(0, 0, 1920, 1080), DateTimeOffset.UtcNow);

        Assert.True(candidate.IsAccepted);
        Assert.Equal("eyouth Coordinator entered the", identity.RawText);
        Assert.Equal("eyouth Coordinator", identity.NormalizedName);
        Assert.Equal(AdmitOnceDecisionKind.FirstFrameAccepted, result.Kind);
    }

    [Fact]
    public void Detect_WhenCodeOccursInIDE_RejectsFalsePositiveCandidate()
    {
        // Code in VS Code editor containing the word Admit
        var codeLine = new OcrLine(
            "public void AutoAdmit(bool shouldAdmit) => Admit();",
            new BoundingRectangleInfo(200, 300, 400, 16),
            new List<OcrWord>
            {
                new("public", new BoundingRectangleInfo(200, 300, 40, 16)),
                new("void", new BoundingRectangleInfo(245, 300, 30, 16)),
                new("Admit", new BoundingRectangleInfo(350, 300, 35, 16))
            });

        var ocrResult = new OcrResult(new List<OcrLine> { codeLine }, codeLine.Words, new BoundingRectangleInfo(0, 0, 1920, 1080));
        var result = WaitingRoomToastDetector.Detect(ocrResult);

        Assert.False(result.IsDetected);
        Assert.Null(result.BestCandidate);
        Assert.Single(result.AllCandidates);
        Assert.False(result.AllCandidates[0].IsAccepted);
        Assert.Contains(result.AllCandidates[0].RejectionReasons, r => r.Contains("code/terminal context", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Detect_WhenAdmitHasNoMatchingView_RejectsCandidate()
    {
        // Single Admit button without View
        var headerLine = new OcrLine(
            "Alice entered the waiting room",
            new BoundingRectangleInfo(100, 100, 250, 15),
            new List<OcrWord> { new("Alice", new BoundingRectangleInfo(100, 100, 35, 15)), new("entered", new BoundingRectangleInfo(140, 100, 50, 15)), new("the", new BoundingRectangleInfo(195, 100, 20, 15)), new("waiting", new BoundingRectangleInfo(220, 100, 45, 15)), new("room", new BoundingRectangleInfo(270, 100, 35, 15)) });

        var admitWord = new OcrWord("Admit", new BoundingRectangleInfo(100, 140, 35, 12));
        var buttonLine = new OcrLine("Admit", new BoundingRectangleInfo(100, 140, 35, 12), new List<OcrWord> { admitWord });

        var allLines = new List<OcrLine> { headerLine, buttonLine };
        var allWords = headerLine.Words.Concat(buttonLine.Words).ToList();
        var ocrResult = new OcrResult(allLines, allWords, new BoundingRectangleInfo(0, 0, 1920, 1080));

        var result = WaitingRoomToastDetector.Detect(ocrResult);

        Assert.False(result.IsDetected);
        Assert.Null(result.BestCandidate);
        Assert.Single(result.AllCandidates);
        Assert.False(result.AllCandidates[0].IsAccepted);
        Assert.Contains(result.AllCandidates[0].RejectionReasons, r => r.Contains("No matching 'View' button found", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Detect_WithMixedNoiseAndRealToast_SelectsRealToastWithHighConfidence()
    {
        // Code noise on left screen (VS Code)
        var codeLine = new OcrLine(
            "const char* Admit = \"Admit\";",
            new BoundingRectangleInfo(100, 200, 200, 15),
            new List<OcrWord> { new("const", new BoundingRectangleInfo(100, 200, 40, 15)), new("Admit", new BoundingRectangleInfo(150, 200, 35, 15)) });

        // Real toast on bottom right
        var headerWords = new List<OcrWord>
        {
            new("Guest", new BoundingRectangleInfo(1500, 800, 40, 15)),
            new("entered", new BoundingRectangleInfo(1545, 800, 50, 15)),
            new("the", new BoundingRectangleInfo(1600, 800, 20, 15)),
            new("waiting", new BoundingRectangleInfo(1625, 800, 45, 15)),
            new("room", new BoundingRectangleInfo(1675, 800, 35, 15))
        };
        var headerLine = new OcrLine("Guest entered the waiting room", new BoundingRectangleInfo(1500, 800, 220, 15), headerWords);

        var realAdmit = new OcrWord("Admit", new BoundingRectangleInfo(1500, 850, 40, 12));
        var realView = new OcrWord("View", new BoundingRectangleInfo(1650, 850, 30, 12));
        var realButtons = new OcrLine("Admit View", new BoundingRectangleInfo(1500, 850, 180, 12), new List<OcrWord> { realAdmit, realView });

        var allLines = new List<OcrLine> { codeLine, headerLine, realButtons };
        var allWords = codeLine.Words.Concat(headerWords).Concat(realButtons.Words).ToList();
        var ocrResult = new OcrResult(allLines, allWords, new BoundingRectangleInfo(0, 0, 1920, 1080));

        var result = WaitingRoomToastDetector.Detect(ocrResult);

        Assert.True(result.IsDetected);
        Assert.NotNull(result.BestCandidate);
        Assert.Equal("Guest", result.BestCandidate.ParticipantName);
        Assert.Equal(1520.0, result.BestCandidate.AdmitCenter.X, precision: 1);
        Assert.Equal(856.0, result.BestCandidate.AdmitCenter.Y, precision: 1);
        Assert.Equal(2, result.AllCandidates.Count);

        var rejected = result.AllCandidates.First(c => !c.IsAccepted);
        Assert.Contains(rejected.RejectionReasons, r => r.Contains("code/terminal context", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Detect_SameRowHorizontalToast_MohabMohamedLiveEvidence_IsAcceptedAtHighConfidence()
    {
        // Exact live evidence:
        // Phrase: "mohab mohamed entered the waiting room" bounds: [489, 269, 254x13]
        // Admit: [772, 269, 39x10]
        // View: [865, 269, 27x10]

        var phraseWords = new List<OcrWord>
        {
            new("mohab", new BoundingRectangleInfo(489, 269, 42, 13)),
            new("mohamed", new BoundingRectangleInfo(535, 269, 58, 13)),
            new("entered", new BoundingRectangleInfo(598, 269, 50, 13)),
            new("the", new BoundingRectangleInfo(652, 269, 22, 13)),
            new("waiting", new BoundingRectangleInfo(678, 269, 48, 13)),
            new("room", new BoundingRectangleInfo(730, 269, 35, 13))
        };
        var phraseLine = new OcrLine(
            "mohab mohamed entered the waiting room",
            new BoundingRectangleInfo(489, 269, 254, 13),
            phraseWords);

        var admitWord = new OcrWord("Admit", new BoundingRectangleInfo(772, 269, 39, 10));
        var viewWord = new OcrWord("View", new BoundingRectangleInfo(865, 269, 27, 10));
        var buttonLine = new OcrLine(
            "Admit View",
            new BoundingRectangleInfo(772, 269, 120, 10),
            new List<OcrWord> { admitWord, viewWord });

        var allLines = new List<OcrLine> { phraseLine, buttonLine };
        var allWords = phraseWords.Concat([admitWord, viewWord]).ToList();
        var ocr = new OcrResult(allLines, allWords, new BoundingRectangleInfo(0, 0, 1920, 1080));

        var result = WaitingRoomToastDetector.Detect(ocr);

        Assert.True(result.IsDetected);
        Assert.NotNull(result.BestCandidate);
        Assert.Equal("mohab mohamed", result.BestCandidate.ParticipantNormalizedName);
        Assert.Equal(WaitingRoomNotificationLayout.InMeetingToast, result.BestCandidate.LayoutType);
        Assert.True(result.BestCandidate.Confidence >= 0.95);
        Assert.Equal(791.5, result.BestCandidate.AdmitCenter.X, precision: 1);
        Assert.Equal(274.0, result.BestCandidate.AdmitCenter.Y, precision: 1);
        Assert.True(result.BestCandidate.IsAccepted);
        Assert.Empty(result.BestCandidate.RejectionReasons);
    }

    [Fact]
    public void SameRowToast_WhenInChromeScreenshot_IsRejectedByRuntimeSafety()
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            "chrome",
            "Chrome_WidgetWin_1",
            "Google Chrome",
            hasZoomParentOwnerChain: false);

        Assert.False(decision.IsAllowed);
        Assert.Contains("Non-Zoom application surface", decision.Reason);
    }

    [Fact]
    public void SameRowToast_WhenInLiveZoomNotificationWndClass_IsAcceptedByRuntimeSafety()
    {
        var decision = NotificationSurfacePolicy.Evaluate(
            WaitingRoomNotificationLayout.InMeetingToast,
            "Zoom",
            "zMeetingNotificationWndClass",
            "Zoom Meeting",
            hasZoomParentOwnerChain: true);

        Assert.True(decision.IsAllowed);
        Assert.Contains("Zoom surface", decision.Reason);
    }

    [Fact]
    public void PrioritySelector_ActionableSameRowToast_SuppressesPanelHoverFallback()
    {
        var sameRowToast = new WaitingRoomToastCandidate
        {
            ParticipantName = "mohab mohamed",
            ParticipantNormalizedName = "mohab mohamed",
            LayoutType = WaitingRoomNotificationLayout.InMeetingToast,
            Confidence = 0.99,
            IsAccepted = true,
            ToastBounds = new(474, 254, 430, 40),
            AdmitWord = new("Admit", new(772, 269, 39, 10)),
            ViewWord = new("View", new(865, 269, 27, 10)),
            HeaderLine = new("mohab mohamed entered the waiting room", new(489, 269, 254, 13), []),
            AdmitCenter = (791.5, 274)
        };

        var panelRow = new WaitingParticipantRowCandidate
        {
            ParticipantName = "mohab mohamed",
            RowBounds = new(1500, 240, 400, 24),
            SafeHoverPoint = (1560, 247),
            Confidence = 0.95
        };

        var chosen = AutoAdmitPrioritySelector.Choose(
            [sameRowToast],
            multiPersonNotification: null,
            panelAdmitAll: null,
            eligiblePanelRow: panelRow);

        Assert.Equal(AutoAdmitPathKind.InMeetingToast, chosen);
    }
}
