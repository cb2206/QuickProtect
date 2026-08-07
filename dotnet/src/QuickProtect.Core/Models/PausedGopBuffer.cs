namespace QuickProtect.Core.Models;

/// <summary>
/// Bounded buffer of compressed video packets collected while display decode
/// is paused (panel hidden during the stream keep-alive grace).
///
/// Keeps exactly the run of packets since the most recent keyframe, so resume
/// can burst-decode one valid GOP and land on the live picture. Packets
/// buffered mid-GOP with no anchoring keyframe are useless (their references
/// were never decoded) and are discarded. A GOP that outgrows the byte limit
/// is dropped wholesale; the buffer stays empty until the next keyframe
/// restarts it, and the caller falls back to waiting for a keyframe on resume.
///
/// Pure — no FFmpeg — so the policy is unit-testable (port of the macOS
/// <c>PausedGOPBuffer</c>, which buffers access units of NALs; the FFmpeg
/// pipeline's unit is one demuxed packet).
/// </summary>
public sealed class PausedGopBuffer
{
    /// <summary>
    /// Several seconds of high-quality H.264/HEVC; a single GOP beyond this is
    /// abnormal and not worth holding per camera.
    /// </summary>
    public const int DefaultByteLimit = 8 * 1024 * 1024;

    private readonly List<byte[]> _packets = new();
    private int _bytes;
    private bool _dropped;
    private readonly int _byteLimit;

    public PausedGopBuffer(int byteLimit = DefaultByteLimit) => _byteLimit = byteLimit;

    public IReadOnlyList<byte[]> Packets => _packets;

    /// <summary>
    /// True when nothing replayable is buffered (paused mid-GOP, or the GOP
    /// overflowed the limit).
    /// </summary>
    public bool IsEmpty => _packets.Count == 0;

    public void Add(byte[] packet, bool isKeyframe)
    {
        if (isKeyframe)
        {
            _packets.Clear();
            _bytes = 0;
            _dropped = false;
        }
        else if (_dropped || _packets.Count == 0)
        {
            return;
        }
        _packets.Add(packet);
        _bytes += packet.Length;
        if (_bytes > _byteLimit)
        {
            _packets.Clear();
            _packets.TrimExcess();
            _bytes = 0;
            _dropped = true;
        }
    }

    /// <summary>Returns the buffered GOP (oldest first) and resets the buffer.</summary>
    public List<byte[]> Drain()
    {
        var gop = new List<byte[]>(_packets);
        _packets.Clear();
        _bytes = 0;
        _dropped = false;
        return gop;
    }
}
