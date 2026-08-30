using ZoomAutoAdmit.UIAutomation.Input;
using Xunit;

namespace ZoomAutoAdmit.UIAutomation.Tests;

public class SingleClickExecutorTests
{
    [Fact]
    public void ExecutorCallsFakeMouseOnlyOnce()
    {
        var fake = new FakeMouseInput();
        var executor = new SingleClickExecutor(fake);

        Assert.True(executor.TryClick(100, 200));
        Assert.False(executor.TryClick(300, 400));
        Assert.Equal(1, fake.ClickCount);
        Assert.Equal((100, 200), fake.LastTarget);
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
