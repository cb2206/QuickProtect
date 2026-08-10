using QuickProtect.Core.Models;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Tests for the render-pause GOP buffer: the pure policy deciding which
/// compressed packets survive a pause so resume can burst-decode a valid GOP
/// (see VideoStreamClient.SetRenderPaused) — the port of the macOS
/// PausedGOPBufferTests.
/// </summary>
public class PausedGopBufferTests
{
    /// <summary>One compressed packet of <paramref name="size"/> bytes.</summary>
    private static byte[] Packet(int size, byte fill = 0)
    {
        var data = new byte[size];
        Array.Fill(data, fill);
        return data;
    }

    [Fact]
    public void Starts_empty_and_ignores_mid_gop_frames()
    {
        var buf = new PausedGopBuffer();
        Assert.True(buf.IsEmpty);
        buf.Add(Packet(100), isKeyframe: false);
        Assert.True(buf.IsEmpty); // frames with no anchoring keyframe are undecodable
    }

    [Fact]
    public void Buffers_from_keyframe()
    {
        var buf = new PausedGopBuffer();
        buf.Add(Packet(100), isKeyframe: true);
        buf.Add(Packet(50), isKeyframe: false);
        Assert.Equal(2, buf.Packets.Count);
    }

    [Fact]
    public void New_keyframe_restarts_buffer()
    {
        var buf = new PausedGopBuffer();
        buf.Add(Packet(100, fill: 1), isKeyframe: true);
        buf.Add(Packet(50, fill: 2), isKeyframe: false);
        buf.Add(Packet(100, fill: 3), isKeyframe: true);
        buf.Add(Packet(50, fill: 4), isKeyframe: false);
        Assert.Equal(2, buf.Packets.Count); // only the latest GOP is kept
        Assert.Equal(3, buf.Packets[0][0]);
    }

    [Fact]
    public void Overflow_drops_gop_until_next_keyframe()
    {
        var buf = new PausedGopBuffer(byteLimit: 200);
        buf.Add(Packet(150), isKeyframe: true);
        buf.Add(Packet(100), isKeyframe: false); // 250 > 200 → dropped
        Assert.True(buf.IsEmpty);
        buf.Add(Packet(50), isKeyframe: false); // still dropped — no keyframe yet
        Assert.True(buf.IsEmpty);
        buf.Add(Packet(50), isKeyframe: true); // fresh keyframe restarts buffering
        buf.Add(Packet(50), isKeyframe: false);
        Assert.Equal(2, buf.Packets.Count);
    }

    [Fact]
    public void Drain_returns_in_order_and_resets()
    {
        var buf = new PausedGopBuffer();
        buf.Add(Packet(10, fill: 1), isKeyframe: true);
        buf.Add(Packet(10, fill: 2), isKeyframe: false);
        var gop = buf.Drain();
        Assert.Equal(2, gop.Count);
        Assert.Equal(1, gop[0][0]);
        Assert.Equal(2, gop[1][0]);
        Assert.True(buf.IsEmpty);
        // The drained buffer accepts a fresh GOP again.
        buf.Add(Packet(10), isKeyframe: true);
        Assert.Single(buf.Packets);
    }

    [Fact]
    public void WantsPacket_matches_what_add_would_store()
    {
        var buf = new PausedGopBuffer(byteLimit: 200);

        // Empty buffer: keyframes wanted, mid-GOP packets not.
        Assert.True(buf.WantsPacket(isKeyframe: true));
        Assert.False(buf.WantsPacket(isKeyframe: false));

        // Anchored GOP: everything wanted.
        buf.Add(Packet(100), isKeyframe: true);
        Assert.True(buf.WantsPacket(isKeyframe: false));
        Assert.True(buf.WantsPacket(isKeyframe: true));

        // Overflowed: only a fresh keyframe restarts buffering.
        buf.Add(Packet(150), isKeyframe: false);
        Assert.True(buf.IsEmpty);
        Assert.False(buf.WantsPacket(isKeyframe: false));
        Assert.True(buf.WantsPacket(isKeyframe: true));

        // After a drain the cycle starts over.
        buf.Add(Packet(50), isKeyframe: true);
        buf.Drain();
        Assert.False(buf.WantsPacket(isKeyframe: false));
        Assert.True(buf.WantsPacket(isKeyframe: true));
    }

    [Fact]
    public void Drain_after_overflow_is_empty_but_reusable()
    {
        var buf = new PausedGopBuffer(byteLimit: 100);
        buf.Add(Packet(150), isKeyframe: true); // immediately over the limit
        Assert.Empty(buf.Drain());
        buf.Add(Packet(50), isKeyframe: true);
        Assert.Single(buf.Packets); // drain clears the dropped state
    }
}
