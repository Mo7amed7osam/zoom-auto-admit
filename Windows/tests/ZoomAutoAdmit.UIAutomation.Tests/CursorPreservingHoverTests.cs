using ZoomAutoAdmit.UIAutomation.Input;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

public class CursorPreservingHoverTests
{
    [Fact]
    public void HoverMovesToTargetAndRestoresOriginalPosition()
    {
        var fake = new FakeCursorController((40, 50));
        var hover = new CursorPreservingHover(fake);

        var result = hover.Run(300, 400, () =>
        {
            Assert.Equal((300, 400), fake.Position);
            return "captured";
        });

        Assert.Equal("captured", result);
        Assert.Equal((40, 50), fake.Position);
        Assert.Equal([(300, 400), (40, 50)], fake.Moves);
    }

    [Fact]
    public void HoverRestoresCursorWhenRecaptureThrows()
    {
        var fake = new FakeCursorController((10, 20));
        var hover = new CursorPreservingHover(fake);

        Assert.Throws<InvalidOperationException>(() =>
            hover.Run<object>(300, 400, () => throw new InvalidOperationException("OCR failed")));

        Assert.Equal((10, 20), fake.Position);
        Assert.Equal([(300, 400), (10, 20)], fake.Moves);
    }

    [Fact]
    public void HoverThenSingleClick_UsesFreshTargetExactlyOnceAndRestoresCursor()
    {
        var cursor = new FakeCursorController((10, 20));
        var mouse = new FakeMouseInput();
        var action = new HoverThenSingleClickExecutor(cursor, mouse);

        bool clicked = action.TryRun(300, 400, () =>
        {
            Assert.Equal((300, 400), cursor.Position);
            return (700, 800);
        });

        Assert.True(clicked);
        Assert.Equal(1, mouse.ClickCount);
        Assert.Equal((700, 800), mouse.LastTarget);
        Assert.Equal((10, 20), cursor.Position);
    }

    [Fact]
    public void HoverThenSingleClick_WhenFreshTargetFails_DoesNotClickAndRestoresCursor()
    {
        var cursor = new FakeCursorController((10, 20));
        var mouse = new FakeMouseInput();
        var action = new HoverThenSingleClickExecutor(cursor, mouse);

        Assert.False(action.TryRun(300, 400, () => null));
        Assert.Equal(0, mouse.ClickCount);
        Assert.Equal((10, 20), cursor.Position);
    }

    [Fact]
    public void CursorRemainsHoveredThroughPostClickVerificationThenRestores()
    {
        var cursor = new FakeCursorController((10, 20));
        var mouse = new FakeMouseInput();
        var action = new HoverThenSingleClickExecutor(cursor, mouse);

        var result = action.RunWithPostClick(
            300,
            400,
            () => (700, 800),
            () =>
            {
                Assert.Equal((300, 400), cursor.Position);
                return true;
            });

        Assert.True(result.ClickSent);
        Assert.True(result.PostClickVerified);
        Assert.Equal((10, 20), cursor.Position);
    }

    [Fact]
    public void SyntheticHoverUsesSteppedMotionAndJiggleWithoutClicking()
    {
        var cursor = new FakeCursorController((10, 20));
        var waits = new List<int>();
        var activator = new SyntheticHoverActivator(cursor, waits.Add);

        var trace = activator.Activate((1500, 150), (1560, 240));

        Assert.Equal((1500, 150), trace.NeutralPoint);
        Assert.Equal((1560, 240), trace.FinalPoint);
        Assert.Equal((1500, 150), cursor.Moves.First());
        Assert.Contains((1563, 240), cursor.Moves);
        Assert.Contains((1557, 240), cursor.Moves);
        Assert.Equal((1560, 240), cursor.Position);
        int firstTargetRowPoint = trace.MovementPoints.ToList().FindIndex(point => point.Y == 240);
        Assert.True(firstTargetRowPoint >= 1);
        Assert.All(trace.MovementPoints.Take(firstTargetRowPoint), point => Assert.Equal(1500, point.X));
        Assert.All(
            trace.MovementPoints.Skip(firstTargetRowPoint).TakeWhile(point => point.X <= 1560),
            point => Assert.Equal(240, point.Y));
        Assert.Contains(75, waits);
        Assert.Contains(400, waits);
    }

    [Fact]
    public void HoverActivationPolicyAllowsOnlyTwoAttemptsAndRequiresVisualChange()
    {
        Assert.True(HoverActivationPolicy.CanAttempt(1));
        Assert.True(HoverActivationPolicy.CanAttempt(2));
        Assert.False(HoverActivationPolicy.CanAttempt(3));
        Assert.False(HoverActivationPolicy.IsActivated(0.49));
        Assert.True(HoverActivationPolicy.IsActivated(0.50));
    }

    [Fact]
    public void CursorSessionRestoresOnlyAfterVerificationAndOnFailure()
    {
        var successCursor = new FakeCursorController((10, 20));
        var success = new CursorPreservingSession(successCursor);
        success.Run(original =>
        {
            Assert.Equal((10, 20), original);
            successCursor.MoveTo(1560, 240);
            Assert.Equal((1560, 240), successCursor.Position);
            return true;
        });
        Assert.Equal((10, 20), successCursor.Position);

        var failureCursor = new FakeCursorController((30, 40));
        var failure = new CursorPreservingSession(failureCursor);
        Assert.Throws<InvalidOperationException>(() => failure.Run<bool>(_ =>
        {
            failureCursor.MoveTo(1600, 250);
            throw new InvalidOperationException("OCR failed");
        }));
        Assert.Equal((30, 40), failureCursor.Position);
    }

    private sealed class FakeCursorController : ICursorController
    {
        public FakeCursorController((int X, int Y) initial) { Position = initial; }
        public (int X, int Y) Position { get; private set; }
        public List<(int X, int Y)> Moves { get; } = new();
        public (int X, int Y) GetPosition() => Position;
        public void MoveTo(int x, int y)
        {
            Position = (x, y);
            Moves.Add(Position);
        }
    }

    private sealed class FakeMouseInput : IMouseInput
    {
        public int ClickCount { get; private set; }
        public (int X, int Y) LastTarget { get; private set; }
        public void LeftClickOncePreservingCursor(int x, int y)
        {
            ClickCount++;
            LastTarget = (x, y);
        }
        public void ScrollWheelPreservingCursor(int x, int y, int wheelDelta)
        {
        }
    }
}
