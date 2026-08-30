using ZoomAutoAdmit.Core.Matching;
using ZoomAutoAdmit.Core.Models;
using Xunit;

namespace ZoomAutoAdmit.Core.Tests;

public class FailedHoverCooldownTests
{
    [Fact]
    public void SameUnchangedRowCoolsDownThenBecomesEligible()
    {
        var row = Row("mohab mohamed", 240);
        var cooldown = new FailedHoverCooldown(TimeSpan.FromMilliseconds(1500));
        var now = DateTimeOffset.UtcNow;
        cooldown.MarkFailed(row, now);

        Assert.True(cooldown.IsCoolingDown(row, now.AddSeconds(1)));
        Assert.False(cooldown.IsCoolingDown(row, now.AddSeconds(2)));
    }

    [Fact]
    public void NewParticipantOrMovedRowBypassesOldCooldown()
    {
        var original = Row("mohab mohamed", 240);
        var cooldown = new FailedHoverCooldown();
        var now = DateTimeOffset.UtcNow;
        cooldown.MarkFailed(original, now);

        Assert.False(cooldown.IsCoolingDown(Row("Ahmed", 240), now.AddMilliseconds(100)));
        Assert.False(cooldown.IsCoolingDown(Row("mohab mohamed", 260), now.AddMilliseconds(100)));
    }

    private static WaitingParticipantRowCandidate Row(string participant, double y) => new()
    {
        ParticipantName = participant,
        TextBounds = new(1510, y, 120, 14),
        RowBounds = new(1485, y - 5, 425, 24),
        Confidence = 0.99
    };
}
