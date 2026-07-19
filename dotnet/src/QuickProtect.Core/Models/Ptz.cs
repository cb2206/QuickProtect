namespace QuickProtect.Core.Models;

/// <summary>PTZ d-pad / keyboard directions.</summary>
public enum PtzDirection
{
    Up,
    Down,
    Left,
    Right,
    ZoomIn,
    ZoomOut
}

/// <summary>
/// Pure mapping from a <see cref="PtzDirection"/> to the per-axis velocity
/// directions sent to the controller (−1 / 0 / +1; null = leave that axis
/// untouched). Matches the macOS app's key/d-pad mapping exactly:
/// Left = pan −1, Right = pan +1, Up = tilt +1, Down = tilt −1,
/// ZoomIn = zoom +1, ZoomOut = zoom −1. Kept here (platform-free) so it is
/// unit-testable without the UI/libVLC layer.
/// </summary>
public static class PtzMapping
{
    public readonly record struct Axes(double? Pan, double? Tilt, double? Zoom);

    /// <summary>Velocity directions for pressing/holding <paramref name="d"/>.</summary>
    public static Axes Press(PtzDirection d) => d switch
    {
        PtzDirection.Left    => new Axes(Pan: -1, null, null),
        PtzDirection.Right   => new Axes(Pan: 1, null, null),
        PtzDirection.Up      => new Axes(null, Tilt: 1, null),
        PtzDirection.Down    => new Axes(null, Tilt: -1, null),
        PtzDirection.ZoomIn  => new Axes(null, null, Zoom: 1),
        PtzDirection.ZoomOut => new Axes(null, null, Zoom: -1),
        _ => new Axes(null, null, null)
    };

    /// <summary>Zero the axis that <paramref name="d"/> drives, on release/key-up.</summary>
    public static Axes Release(PtzDirection d) => d switch
    {
        PtzDirection.Left or PtzDirection.Right   => new Axes(Pan: 0, null, null),
        PtzDirection.Up or PtzDirection.Down      => new Axes(null, Tilt: 0, null),
        PtzDirection.ZoomIn or PtzDirection.ZoomOut => new Axes(null, null, Zoom: 0),
        _ => new Axes(null, null, null)
    };
}
