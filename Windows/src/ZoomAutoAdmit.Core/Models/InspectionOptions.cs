namespace ZoomAutoAdmit.Core.Models;

public record InspectionOptions
{
    public int MaxDepth { get; init; } = 15;
    public int MaxElements { get; init; } = 800;
    public bool IncludeAllDetails { get; init; } = false;
    public string? SearchFilter { get; init; }
    public int? TargetProcessId { get; init; }
    public bool ShowPatternsOnlyWhenPresent { get; init; } = true;
}

public record InspectionSummary(
    int TotalElementsVisited,
    int TotalElementsMatched,
    int MaxDepthReached,
    bool DepthTruncated,
    bool ElementCountTruncated,
    TimeSpan ElapsedTime,
    IReadOnlyList<string> DiagnosticWarnings
);
