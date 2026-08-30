using System.Text.RegularExpressions;
using ZoomAutoAdmit.Core.Models;

namespace ZoomAutoAdmit.Core.Matching;

/// <summary>
/// Pure OCR-geometry strategy for the visible Zoom Participants panel. It does
/// not use UI Automation, move the cursor, or send input.
/// </summary>
public static class WaitingRoomParticipantRowDetector
{
    private static readonly Regex ParticipantsHeaderPattern = new(
        @"(?:zm\s+)?Participants(?:\s*\(\d+\))?",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex WaitingRoomHeaderPattern = new(
        @"Waiting\s+room(?:\s*\(\d+\))?",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex JoinedHeaderPattern = new(
        @"Joined(?:\s*\(\d+\))?",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex GuestSuffixPattern = new(
        @"\s*\(Guest\)\s*$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex NonParticipantPattern = new(
        @"^(?:Admit(?:\s+all)?|View|More|Invite|Mute(?:\s+All)?|Unmute(?:\s+All)?|Search|Participants|Waiting\s+room(?:\s*\(\d+\))?|Joined(?:\s*\(\d+\))?)$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static ParticipantsPanelDetectionResult Detect(OcrResult ocr)
    {
        var rejectionReasons = new List<string>();
        var participantsHeaders = ocr.Lines.Where(line => ParticipantsHeaderPattern.IsMatch(line.Text.Trim())).ToList();
        var waitingHeaders = ocr.Lines.Where(line => WaitingRoomHeaderPattern.IsMatch(line.Text.Trim())).ToList();
        var joinedHeaders = ocr.Lines.Where(line => JoinedHeaderPattern.IsMatch(line.Text.Trim())).ToList();

        if (participantsHeaders.Count == 0) rejectionReasons.Add("Participants header was not found.");
        if (waitingHeaders.Count == 0) rejectionReasons.Add("Waiting room header was not found.");
        if (participantsHeaders.Count == 0 || waitingHeaders.Count == 0)
        {
            return new ParticipantsPanelDetectionResult
            {
                ParticipantsHeader = participantsHeaders.FirstOrDefault(),
                WaitingRoomHeader = waitingHeaders.FirstOrDefault(),
                RejectionReasons = rejectionReasons
            };
        }

        (OcrLine Participants, OcrLine Waiting, OcrLine? Joined)? best = null;
        double bestScore = double.MinValue;
        foreach (var waiting in waitingHeaders)
        {
            foreach (var participants in participantsHeaders)
            {
                double verticalGap = waiting.Bounds.Y - (participants.Bounds.Y + participants.Bounds.Height);
                double horizontalDelta = Math.Abs(waiting.Bounds.X - participants.Bounds.X);
                if (verticalGap < -5 || verticalGap > 1000 || horizontalDelta > 250)
                {
                    continue;
                }

                var joined = joinedHeaders
                    .Where(line => line.Bounds.Y > waiting.Bounds.Y && Math.Abs(line.Bounds.X - waiting.Bounds.X) <= 250)
                    .OrderBy(line => line.Bounds.Y)
                    .FirstOrDefault();

                double score = (joined != null ? 3 : 0) - horizontalDelta / 250.0;
                if (score > bestScore)
                {
                    bestScore = score;
                    best = (participants, waiting, joined);
                }
            }
        }

        if (best == null)
        {
            rejectionReasons.Add("Participants and Waiting room headers do not form a valid panel geometry.");
            return new ParticipantsPanelDetectionResult { RejectionReasons = rejectionReasons };
        }

        var selected = best.Value;

        double imageRight = ocr.ImageBounds.X + ocr.ImageBounds.Width;
        double imageBottom = ocr.ImageBounds.Y + ocr.ImageBounds.Height;
        double panelLeft = Math.Max(ocr.ImageBounds.X, Math.Min(selected.Participants.Bounds.X, selected.Waiting.Bounds.X) - 20);
        double linesMaxRight = ocr.Lines
            .Where(l => l.Bounds.Y >= selected.Participants.Bounds.Y - 20 &&
                        l.Bounds.Y <= (selected.Joined?.Bounds.Y ?? (selected.Waiting.Bounds.Y + 400)) + 300 &&
                        Math.Abs(l.Bounds.X - panelLeft) <= 500)
            .Select(l => l.Bounds.X + l.Bounds.Width)
            .DefaultIfEmpty(panelLeft + 350)
            .Max();
        double panelRight = Math.Max(panelLeft + 320, linesMaxRight + 30);
        if (ocr.ImageBounds.Width > 0 && panelRight > imageRight) panelRight = imageRight;
        double panelBottom = selected.Joined?.Bounds.Bottom() ?? imageBottom;
        var panelBounds = new BoundingRectangleInfo(
            panelLeft,
            Math.Max(ocr.ImageBounds.Y, selected.Participants.Bounds.Y - 10),
            Math.Max(0, panelRight - panelLeft),
            Math.Max(0, panelBottom + (selected.Joined?.Bounds.Height ?? 0) + 10 - Math.Max(ocr.ImageBounds.Y, selected.Participants.Bounds.Y - 10)));

        double rowAreaTop = selected.Waiting.Bounds.Y + selected.Waiting.Bounds.Height + 2;
        double rowAreaBottom = selected.Joined?.Bounds.Y ?? Math.Min(imageBottom, rowAreaTop + 400);
        var rowLines = ocr.Lines
            .Where(line => line.Bounds.Y >= rowAreaTop &&
                           line.Bounds.Y + line.Bounds.Height <= rowAreaBottom + 2 &&
                           line.Bounds.X >= panelLeft - 5 &&
                           line.Bounds.X < panelRight &&
                           !string.IsNullOrWhiteSpace(line.Text) &&
                           !NonParticipantPattern.IsMatch(line.Text.Trim()))
            .OrderBy(line => line.Bounds.Y)
            .ThenBy(line => line.Bounds.X)
            .ToList();

        var groups = GroupSameVisualRow(rowLines);
        var rows = new List<WaitingParticipantRowCandidate>();
        foreach (var group in groups)
        {
            var orderedWords = group.SelectMany(line => line.Words).OrderBy(word => word.Bounds.X).ToList();
            double firstActionX = orderedWords
                .Where(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase) ||
                               word.Text.Trim().Equals("More", StringComparison.OrdinalIgnoreCase) ||
                               word.Text.Trim().Equals("...", StringComparison.Ordinal))
                .Select(word => word.Bounds.X)
                .DefaultIfEmpty(double.MaxValue)
                .Min();
            var preActionWords = orderedWords.Where(word => word.Bounds.X < firstActionX).ToList();
            int guestIndex = preActionWords.FindIndex(word =>
                word.Text.Contains("(Guest)", StringComparison.OrdinalIgnoreCase) ||
                word.Text.Trim(' ', '(', ')').Equals("Guest", StringComparison.OrdinalIgnoreCase));
            var participantWords = guestIndex >= 0
                ? preActionWords.Take(guestIndex).ToList()
                : preActionWords;
            string rawText = participantWords.Count > 0
                ? string.Join(" ", participantWords.Select(word => word.Text.Trim())).Trim()
                : Regex.Split(
                        string.Join(" ", group.OrderBy(line => line.Bounds.X).Select(line => line.Text.Trim())),
                        @"\bAdmit\b|\.{3}",
                        RegexOptions.IgnoreCase)[0].Trim();
            string participantName = GuestSuffixPattern.Replace(rawText, string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(participantName) || NonParticipantPattern.IsMatch(participantName))
            {
                continue;
            }

            var textBounds = participantWords.Count > 0
                ? Union(participantWords.Select(word => word.Bounds))
                : Union(group.Select(line => line.Bounds));
            double rowTop = Math.Max(rowAreaTop, textBounds.Y - 8);
            double rowBottom = Math.Min(rowAreaBottom, textBounds.Y + textBounds.Height + 8);
            if (rowBottom - rowTop < 24)
            {
                double expand = (24 - (rowBottom - rowTop)) / 2;
                rowTop = Math.Max(rowAreaTop, rowTop - expand);
                rowBottom = Math.Min(rowAreaBottom, rowBottom + expand);
            }

            var rowBounds = new BoundingRectangleInfo(
                panelLeft + 5,
                rowTop,
                Math.Max(0, panelRight - panelLeft - 10),
                Math.Max(0, rowBottom - rowTop));
            double safeRightLimit = panelLeft + rowBounds.Width * 0.58;
            double hoverX = Math.Clamp(
                textBounds.X + Math.Min(Math.Max(textBounds.Width * 0.20, 12), 60),
                rowBounds.X + 10,
                Math.Max(rowBounds.X + 10, safeRightLimit));
            double hoverY = textBounds.Y + textBounds.Height / 2.0;
            double confidence = 0.25 + 0.25 + (selected.Joined != null ? 0.20 : 0.11) +
                                (guestIndex >= 0 || GuestSuffixPattern.IsMatch(rawText) ? 0.15 : 0.08) + 0.14;

            rows.Add(new WaitingParticipantRowCandidate
            {
                RawText = rawText,
                ParticipantName = participantName,
                TextBounds = textBounds,
                RowBounds = rowBounds,
                SafeHoverPoint = (hoverX, hoverY),
                Confidence = Math.Min(0.99, confidence)
            });
        }

        int? declaredWaitingCount = ExtractCount(selected.Waiting.Text);
        var finalRows = (declaredWaitingCount == 0)
            ? (IReadOnlyList<WaitingParticipantRowCandidate>)Array.Empty<WaitingParticipantRowCandidate>()
            : rows.OrderBy(row => row.RowBounds.Y).ToList();

        return new ParticipantsPanelDetectionResult
        {
            IsPanelVisible = true,
            ParticipantsHeader = selected.Participants,
            WaitingRoomHeader = selected.Waiting,
            JoinedHeader = selected.Joined,
            DeclaredWaitingCount = declaredWaitingCount,
            PanelBounds = panelBounds,
            Rows = finalRows,
            RejectionReasons = rejectionReasons
        };
    }

    public static HoverAdmitValidationResult ValidateIndividualAdmitAfterHover(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel,
        OcrResult postHoverOcr)
    {
        var reasons = new List<string>();
        if (!originalPanel.IsPanelVisible || originalPanel.WaitingRoomHeader == null)
        {
            reasons.Add("The trusted pre-hover Participants panel geometry is incomplete.");
            return new HoverAdmitValidationResult { RejectionReasons = reasons };
        }

        var evaluations = EvaluateIndividualAdmitsAfterHover(originalRow, originalPanel, postHoverOcr);
        var accepted = evaluations.FirstOrDefault(evaluation => evaluation.IsAccepted);
        if (accepted != null)
        {
            return new HoverAdmitValidationResult
            {
                IsConfirmed = true,
                Row = originalRow,
                AdmitWord = accepted.AdmitWord,
                AdmitCenter = accepted.AdmitWord.Center,
                Confidence = 0.99
            };
        }

        if (evaluations.Count == 0) reasons.Add("Exact individual Admit word did not appear after hover.");
        else reasons.Add("Admit words were rejected as Admit All, toast/outside-panel, or belonging to another row.");
        return new HoverAdmitValidationResult { Row = originalRow, RejectionReasons = reasons };
    }

    public static IReadOnlyList<PostHoverAdmitEvaluation> EvaluateIndividualAdmitsAfterHover(
        WaitingParticipantRowCandidate originalRow,
        ParticipantsPanelDetectionResult originalPanel,
        OcrResult postHoverOcr)
    {
        if (!originalPanel.IsPanelVisible || originalPanel.WaitingRoomHeader == null)
            return Array.Empty<PostHoverAdmitEvaluation>();

        double allowedTop = Math.Max(
            originalPanel.WaitingRoomHeader.Bounds.Y + originalPanel.WaitingRoomHeader.Bounds.Height,
            originalRow.RowBounds.Y - 12);
        double allowedBottom = originalRow.RowBounds.Y + originalRow.RowBounds.Height + 12;
        if (originalPanel.JoinedHeader != null)
            allowedBottom = Math.Min(allowedBottom, originalPanel.JoinedHeader.Bounds.Y - 1);
        double originalCenterY = originalRow.RowBounds.Y + originalRow.RowBounds.Height / 2.0;
        foreach (var otherRow in originalPanel.Rows.Where(row => !ReferenceEquals(row, originalRow)))
        {
            double otherCenterY = otherRow.RowBounds.Y + otherRow.RowBounds.Height / 2.0;
            double boundary = (originalCenterY + otherCenterY) / 2.0;
            if (otherCenterY < originalCenterY) allowedTop = Math.Max(allowedTop, boundary);
            if (otherCenterY > originalCenterY) allowedBottom = Math.Min(allowedBottom, boundary);
        }

        var exactAdmitWords = postHoverOcr.Words
            .Where(word => word.Text.Trim().Equals("Admit", StringComparison.OrdinalIgnoreCase))
            .ToList();
        var expanded = new BoundingRectangleInfo(
            originalRow.RowBounds.X,
            allowedTop,
            originalRow.RowBounds.Width,
            Math.Max(0, allowedBottom - allowedTop));
        var toastAdmits = WaitingRoomToastDetector.Detect(postHoverOcr).AllCandidates
            .Where(candidate => candidate.IsAccepted && candidate.AdmitWord != null)
            .Select(candidate => candidate.AdmitWord!.Bounds)
            .ToList();
        var evaluations = new List<PostHoverAdmitEvaluation>();
        foreach (var admit in exactAdmitWords)
        {
            bool isAdmitAll = postHoverOcr.Lines.Any(line =>
                VerticallyContains(line.Bounds, admit.Center.Y) &&
                Regex.IsMatch(line.Text, @"\bAdmit\s+all\b", RegexOptions.IgnoreCase));
            bool insideTrustedRow = admit.Center.Y >= allowedTop && admit.Center.Y <= allowedBottom;
            // Zoom truncates/reflows a long participant name when hover reveals
            // Admit. The live button can therefore occupy pixels that belonged
            // to the pre-hover suffix. Validate against the trusted right-side
            // action zone and the stable activation point, not the old text end.
            double minimumActionX = Math.Max(
                originalRow.RowBounds.X + originalRow.RowBounds.Width * 0.40,
                originalRow.SafeHoverPoint.X + 16);
            bool rightOfOriginalName = admit.Bounds.X >= minimumActionX;
            bool insideOriginalPanel = Contains(originalPanel.PanelBounds, admit.Center.X, admit.Center.Y);
            bool aboveJoined = originalPanel.JoinedHeader == null || admit.Center.Y < originalPanel.JoinedHeader.Bounds.Y;
            bool isToastAdmit = toastAdmits.Any(bounds => bounds.Equals(admit.Bounds));
            bool accepted = !isAdmitAll && insideTrustedRow && rightOfOriginalName && insideOriginalPanel && aboveJoined && !isToastAdmit;
            string rejection = accepted ? string.Empty : string.Join(", ", new[]
            {
                isAdmitAll ? "Admit all" : null,
                !insideTrustedRow ? "outside expanded original row" : null,
                !rightOfOriginalName ? "not right of original participant text" : null,
                !insideOriginalPanel ? "outside original panel" : null,
                !aboveJoined ? "not above Joined" : null,
                isToastAdmit ? "belongs to toast" : null
            }.Where(reason => reason != null));
            evaluations.Add(new PostHoverAdmitEvaluation
            {
                AdmitWord = admit,
                ExpandedRowBounds = expanded,
                InsidePanel = insideOriginalPanel,
                InsideExpandedRow = insideTrustedRow,
                RightOfParticipant = rightOfOriginalName,
                AboveJoined = aboveJoined,
                IsAdmitAll = isAdmitAll,
                IsToastAdmit = isToastAdmit,
                IsAccepted = accepted,
                RejectionReason = rejection
            });
        }
        return evaluations;
    }

    private static int? ExtractCount(string text)
    {
        var match = Regex.Match(text, @"\((?<count>\d+)\)");
        return match.Success && int.TryParse(match.Groups["count"].Value, out int count) ? count : null;
    }

    private static List<List<OcrLine>> GroupSameVisualRow(IReadOnlyList<OcrLine> lines)
    {
        var groups = new List<List<OcrLine>>();
        foreach (var line in lines)
        {
            double centerY = line.Bounds.Y + line.Bounds.Height / 2.0;
            var group = groups.FirstOrDefault(existing =>
                Math.Abs(existing.Average(item => item.Bounds.Y + item.Bounds.Height / 2.0) - centerY) <= 10);
            if (group == null)
            {
                group = new List<OcrLine>();
                groups.Add(group);
            }
            group.Add(line);
        }
        return groups;
    }

    private static BoundingRectangleInfo Union(IEnumerable<BoundingRectangleInfo> bounds)
    {
        var values = bounds.ToList();
        double left = values.Min(value => value.X);
        double top = values.Min(value => value.Y);
        double right = values.Max(value => value.X + value.Width);
        double bottom = values.Max(value => value.Y + value.Height);
        return new BoundingRectangleInfo(left, top, right - left, bottom - top);
    }

    private static bool Contains(BoundingRectangleInfo bounds, double x, double y) =>
        x >= bounds.X && x <= bounds.X + bounds.Width &&
        y >= bounds.Y && y <= bounds.Y + bounds.Height;

    private static bool VerticallyContains(BoundingRectangleInfo bounds, double y) =>
        y >= bounds.Y && y <= bounds.Y + bounds.Height;

    private static double Bottom(this BoundingRectangleInfo bounds) => bounds.Y + bounds.Height;
}
