using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Tests for <see cref="StreamAllocationLedger"/>: the controller shares one
/// allocation per camera and quality between the panel and a pinned window, so
/// a DELETE must wait until neither side holds or is creating it.
/// </summary>
public class StreamAllocationLedgerTests
{
    private const string Key = "cam1:high";

    private static StreamAllocationLedger Holding(params StreamOwner[] owners)
    {
        var ledger = new StreamAllocationLedger();
        foreach (var owner in owners)
        {
            ledger.BeginCreate(Key);
            ledger.EndCreate(Key, owner, succeeded: true);
        }
        return ledger;
    }

    [Fact]
    public void Key_combines_camera_and_quality()
        => Assert.Equal("cam1:high", StreamAllocationLedger.Key("cam1", "high"));

    [Fact]
    public void Sole_owner_release_is_due()
        => Assert.True(Holding(StreamOwner.Panel).Release(Key, StreamOwner.Panel));

    [Fact]
    public void Release_by_a_non_owner_is_ignored()
        => Assert.False(Holding(StreamOwner.Panel).Release(Key, StreamOwner.Pinned));

    [Fact]
    public void Release_is_not_repeated()
    {
        var ledger = Holding(StreamOwner.Panel);
        Assert.True(ledger.Release(Key, StreamOwner.Panel));
        Assert.False(ledger.Release(Key, StreamOwner.Panel));
    }

    [Fact]
    public void Panel_release_keeps_an_allocation_a_pinned_window_holds()
    {
        var ledger = Holding(StreamOwner.Panel, StreamOwner.Pinned);
        Assert.False(ledger.Release(Key, StreamOwner.Panel));
        Assert.True(ledger.Release(Key, StreamOwner.Pinned));
    }

    [Fact]
    public void Panel_cleanup_skips_keys_a_pinned_window_holds()
    {
        var ledger = Holding(StreamOwner.Panel, StreamOwner.Pinned);
        ledger.BeginCreate("cam2:low");
        ledger.EndCreate("cam2:low", StreamOwner.Panel, succeeded: true);

        Assert.Equal(new[] { "cam2:low" }, ledger.ReleaseAll(StreamOwner.Panel));
        Assert.Equal(new[] { Key }, ledger.ReleaseAll(StreamOwner.Pinned));
    }

    [Fact]
    public void Release_during_another_owners_creation_is_dropped_when_it_succeeds()
    {
        // Pinning the camera open in focus: the panel closes while the pinned
        // window's POST is in flight. Deleting then would kill the URL the pin
        // is about to receive.
        var ledger = Holding(StreamOwner.Panel);
        ledger.BeginCreate(Key);

        Assert.Empty(ledger.ReleaseAll(StreamOwner.Panel));
        Assert.False(ledger.EndCreate(Key, StreamOwner.Pinned, succeeded: true));
        Assert.True(ledger.Release(Key, StreamOwner.Pinned));
    }

    [Fact]
    public void Release_during_a_creation_that_fails_is_sent_afterwards()
    {
        var ledger = Holding(StreamOwner.Panel);
        ledger.BeginCreate(Key);

        Assert.False(ledger.Release(Key, StreamOwner.Panel));
        Assert.True(ledger.EndCreate(Key, StreamOwner.Pinned, succeeded: false));
    }

    [Fact]
    public void Deferred_release_waits_for_every_concurrent_creation()
    {
        var ledger = Holding(StreamOwner.Panel);
        ledger.BeginCreate(Key);
        ledger.BeginCreate(Key);

        Assert.False(ledger.Release(Key, StreamOwner.Panel));
        Assert.False(ledger.EndCreate(Key, StreamOwner.Pinned, succeeded: false));
        Assert.True(ledger.EndCreate(Key, StreamOwner.Panel, succeeded: false));
    }

    [Fact]
    public void Failed_creation_without_a_deferred_release_sends_nothing()
    {
        var ledger = new StreamAllocationLedger();
        ledger.BeginCreate(Key);
        Assert.False(ledger.EndCreate(Key, StreamOwner.Panel, succeeded: false));
    }
}
