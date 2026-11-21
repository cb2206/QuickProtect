using System.Globalization;

namespace QuickProtect.Core.Services;

/// <summary>
/// Bytes received from the controllers' video streams, for the bitrate shown
/// next to the stream count in the panel header. Fed by
/// <see cref="RtspTlsTunnel"/>'s downstream pump: every stream is RTSPS and
/// goes through the tunnel, so this is the app's whole video download.
/// macOS counterpart: <c>StreamTraffic</c> (fed by <c>RTSPClient</c>).
/// </summary>
public static class StreamTraffic
{
    private static long _totalBytes;

    public static long TotalBytes => Interlocked.Read(ref _totalBytes);

    public static void Add(int bytes) => Interlocked.Add(ref _totalBytes, bytes);
}

/// <summary>Turns a running byte total into a rate between two samples.</summary>
public sealed class BitrateMeter
{
    private long _lastBytes;
    private TimeSpan _lastTime;
    private bool _hasSample;

    /// <summary>
    /// Bits per second since the previous sample, or null for the first one,
    /// a clock that didn't advance, or a total that went backwards.
    /// </summary>
    public double? Sample(long totalBytes, TimeSpan now)
    {
        var (lastBytes, lastTime, had) = (_lastBytes, _lastTime, _hasSample);
        (_lastBytes, _lastTime, _hasSample) = (totalBytes, now, true);
        if (!had || now <= lastTime || totalBytes < lastBytes) return null;
        return (totalBytes - lastBytes) * 8 / (now - lastTime).TotalSeconds;
    }

    public void Reset() => _hasSample = false;

    /// <summary>
    /// "850 kbps" below one megabit, "4.2 Mbps" above (decimal separator from
    /// <paramref name="culture"/>). Units stay untranslated, like the macOS app.
    /// </summary>
    public static string Format(double bitsPerSecond, CultureInfo culture)
        => bitsPerSecond < 999_500
            ? Math.Round(bitsPerSecond / 1000).ToString("0", culture) + " kbps"
            : (bitsPerSecond / 1_000_000).ToString("0.0", culture) + " Mbps";
}
