namespace QuickProtect.Core.Models;

/// <summary>
/// User-selectable RTSP stream quality. <c>High</c>/<c>Medium</c>/<c>Low</c> map
/// directly to the <c>qualities</c> key the rtsps-stream endpoint accepts;
/// <c>Auto</c> is a UI-level choice that resolves to a concrete quality based on
/// whether the camera is enlarged (low in the grid, high in focus).
/// Mirrors <c>StreamQuality</c> in the macOS app.
/// </summary>
public enum StreamQuality
{
    Auto,
    High,
    Medium,
    Low
}

public static class StreamQualityExtensions
{
    /// <summary>Lower-case wire value used in settings storage and the API.</summary>
    public static string RawValue(this StreamQuality q) => q switch
    {
        StreamQuality.Auto => "auto",
        StreamQuality.High => "high",
        StreamQuality.Medium => "medium",
        StreamQuality.Low => "low",
        _ => "auto"
    };

    /// <summary>
    /// Concrete substream key for the rtsps-stream endpoint. <c>Auto</c> must be
    /// resolved with <see cref="Resolve"/> first; a raw <c>Auto</c> falls back to medium.
    /// </summary>
    public static string ApiValue(this StreamQuality q) =>
        q == StreamQuality.Auto ? "medium" : q.RawValue();

    /// <summary>
    /// Resolve <c>Auto</c> to a concrete quality for the current view state:
    /// high in focus, and in the grid medium for a large tile / low otherwise.
    /// Pass-through for explicit cases.
    /// </summary>
    public static StreamQuality Resolve(this StreamQuality q, bool focused, bool gridIsLarge = false)
    {
        if (q != StreamQuality.Auto) return q;
        if (focused) return StreamQuality.High;
        return gridIsLarge ? StreamQuality.Medium : StreamQuality.Low;
    }

    /// <summary>Resolution ordering (low &lt; medium &lt; high); Auto sits with medium.</summary>
    public static int Rank(this StreamQuality q) => q switch
    {
        StreamQuality.Low => 0,
        StreamQuality.Auto => 1,
        StreamQuality.Medium => 1,
        StreamQuality.High => 2,
        _ => 1
    };

    public static StreamQuality? FromRawValue(string? raw) => raw switch
    {
        "auto" => StreamQuality.Auto,
        "high" => StreamQuality.High,
        "medium" => StreamQuality.Medium,
        "low" => StreamQuality.Low,
        _ => null
    };
}
