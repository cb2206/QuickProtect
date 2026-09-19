namespace QuickProtect.Core.Models;

/// <summary>
/// Digital zoom + pan state for the focus view, mirroring the macOS gesture
/// zoom (1–8× with drag-to-pan, <c>CameraGridView.swift</c>). The visible
/// window is a normalised centre plus a zoom factor; <c>VideoSurface</c> turns
/// it into a source rectangle at draw time. Pure math, unit-tested; the view
/// layer feeds it key/wheel input.
/// </summary>
public sealed class DigitalZoom
{
    public const double MinZoom = 1.0;
    public const double MaxZoom = 8.0;
    /// <summary>Multiplicative step per zoom-in/out tick.</summary>
    public const double Step = 1.25;

    /// <summary>Current magnification (1 = full frame).</summary>
    public double Zoom { get; private set; } = MinZoom;

    // Normalized center of the visible window (0..1 in source coordinates).
    public double CenterX { get; private set; } = 0.5;
    public double CenterY { get; private set; } = 0.5;

    public bool IsZoomed => Zoom > MinZoom + 1e-9;

    public void ZoomIn() => SetZoom(Zoom * Step);
    public void ZoomOut() => SetZoom(Zoom / Step);

    public void SetZoom(double zoom)
    {
        Zoom = Math.Clamp(zoom, MinZoom, MaxZoom);
        if (!IsZoomed) { CenterX = 0.5; CenterY = 0.5; }
        else ClampCenter();
    }

    public void Reset()
    {
        Zoom = MinZoom;
        CenterX = 0.5;
        CenterY = 0.5;
    }

    /// <summary>
    /// Pans by a fraction of the *visible* window (so panning feels constant
    /// regardless of zoom level). +x moves the view right, +y moves it down.
    /// </summary>
    public void Pan(double dxFraction, double dyFraction)
    {
        if (!IsZoomed) return;
        CenterX += dxFraction / Zoom;
        CenterY += dyFraction / Zoom;
        ClampCenter();
    }

    /// <summary>Keep the visible window fully inside the source frame.</summary>
    private void ClampCenter()
    {
        var half = 0.5 / Zoom;
        CenterX = Math.Clamp(CenterX, half, 1 - half);
        CenterY = Math.Clamp(CenterY, half, 1 - half);
    }
}
