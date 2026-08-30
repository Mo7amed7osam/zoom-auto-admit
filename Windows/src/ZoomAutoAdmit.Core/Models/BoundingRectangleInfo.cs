namespace ZoomAutoAdmit.Core.Models;

public record BoundingRectangleInfo(double X, double Y, double Width, double Height)
{
    public override string ToString() => $"[{X:F0}, {Y:F0}, {Width:F0}x{Height:F0}]";

    public bool Contains(double x, double y) =>
        Width > 0 && Height > 0 &&
        x >= X && x <= X + Width &&
        y >= Y && y <= Y + Height;

    public static BoundingRectangleInfo Empty => new(0, 0, 0, 0);
}
