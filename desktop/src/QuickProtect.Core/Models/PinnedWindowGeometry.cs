namespace QuickProtect.Core.Models;

/// <summary>
/// Pure sizing math for a pinned floating window, kept free of any windowing
/// state so it is unit-testable. Direct port of the macOS <c>PinnedWindowGeometry</c>.
/// </summary>
public static class PinnedWindowGeometry
{
    public const double MinWidth = 200;
    public const double MaxWidth = 1600;
    public const double FallbackAspect = 16.0 / 9.0;

    public readonly record struct Size(double Width, double Height);

    /// <summary>
    /// Default content size for a freshly pinned window: <paramref name="targetWidth"/>
    /// scaled to the camera's aspect ratio (width ÷ height), clamped to a sane range.
    /// </summary>
    public static Size DefaultSize(double aspectRatio, double targetWidth = 360)
    {
        var ar = aspectRatio > 0 ? aspectRatio : FallbackAspect;
        var w = Math.Round(Math.Clamp(targetWidth, MinWidth, MaxWidth));
        return new Size(w, Math.Round(w / ar));
    }

    /// <summary>
    /// Constrain a proposed size to <paramref name="aspectRatio"/>, driving from
    /// width so a corner drag keeps the camera's proportions. Width is clamped.
    /// </summary>
    public static Size Constrain(double proposedWidth, double aspectRatio)
    {
        var ar = aspectRatio > 0 ? aspectRatio : FallbackAspect;
        var w = Math.Round(Math.Clamp(proposedWidth, MinWidth, MaxWidth));
        return new Size(w, Math.Round(w / ar));
    }
}
