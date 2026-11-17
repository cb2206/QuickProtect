using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using QuickProtect.App.Platform;

namespace QuickProtect.App.Views;

/// <summary>
/// Invisible resize handles along a borderless window's edges and corners.
///
/// <c>WindowDecorations="None"</c> means the window manager draws no frame, so
/// on floating X11 window managers (GNOME/mutter) there is no border to grab —
/// Avalonia treats that as by design. Each handle asks the window manager to
/// run the resize (<see cref="Window.BeginResizeDrag"/>, _NET_WM_MOVERESIZE on
/// X11), the same mechanism the header already uses for moving. A window
/// manager that ignores the request leaves the handles inert; its own resize
/// gestures keep working.
///
/// Place it as the last child of the window's root panel so it sits on top.
/// Hidden while the window isn't in its normal state (fullscreen, maximized).
/// </summary>
public sealed class ResizeGrips : Panel
{
    /// <summary>Include the top and bottom edges (off for windows whose height follows their width).</summary>
    public static readonly StyledProperty<bool> VerticalEdgesProperty =
        AvaloniaProperty.Register<ResizeGrips, bool>(nameof(VerticalEdges), true);

    public bool VerticalEdges
    {
        get => GetValue(VerticalEdgesProperty);
        set => SetValue(VerticalEdgesProperty, value);
    }

    private const double EdgeThickness = 4;
    private const double CornerSize = 12;

    private readonly Control _top, _bottom;
    private Window? _window;

    public ResizeGrips()
    {
        _top = Grip(WindowEdge.North, StandardCursorType.TopSide, HorizontalAlignment.Stretch, VerticalAlignment.Top, double.NaN, EdgeThickness);
        _bottom = Grip(WindowEdge.South, StandardCursorType.BottomSide, HorizontalAlignment.Stretch, VerticalAlignment.Bottom, double.NaN, EdgeThickness);
        Grip(WindowEdge.West, StandardCursorType.LeftSide, HorizontalAlignment.Left, VerticalAlignment.Stretch, EdgeThickness, double.NaN);
        Grip(WindowEdge.East, StandardCursorType.RightSide, HorizontalAlignment.Right, VerticalAlignment.Stretch, EdgeThickness, double.NaN);
        // Corners last: they overlap the edges and win the hit test.
        Grip(WindowEdge.NorthWest, StandardCursorType.TopLeftCorner, HorizontalAlignment.Left, VerticalAlignment.Top, CornerSize, CornerSize);
        Grip(WindowEdge.NorthEast, StandardCursorType.TopRightCorner, HorizontalAlignment.Right, VerticalAlignment.Top, CornerSize, CornerSize);
        Grip(WindowEdge.SouthWest, StandardCursorType.BottomLeftCorner, HorizontalAlignment.Left, VerticalAlignment.Bottom, CornerSize, CornerSize);
        Grip(WindowEdge.SouthEast, StandardCursorType.BottomRightCorner, HorizontalAlignment.Right, VerticalAlignment.Bottom, CornerSize, CornerSize);
    }

    private Control Grip(WindowEdge edge, StandardCursorType cursor,
        HorizontalAlignment h, VerticalAlignment v, double width, double height)
    {
        // A transparent (not null) background is what makes the handle hit-testable.
        var grip = new Border
        {
            Background = Brushes.Transparent,
            Cursor = new Cursor(cursor),
            HorizontalAlignment = h,
            VerticalAlignment = v,
            Width = width,
            Height = height
        };
        grip.PointerPressed += (_, e) =>
        {
            if (_window is not { CanResize: true } window) return;
            if (!e.GetCurrentPoint(grip).Properties.IsLeftButtonPressed) return;
            if (Hyprland.IsRunning) BeginOwnResize(window, edge, e);
            else window.BeginResizeDrag(edge, e);
            e.Handled = true;
        };
        grip.PointerMoved += (_, e) => ContinueOwnResize();
        grip.PointerReleased += (_, e) => _resize = null;
        grip.PointerCaptureLost += (_, e) => _resize = null;
        Children.Add(grip);
        return grip;
    }

    // MARK: - Resizing without the window manager (Hyprland)
    //
    // Hyprland never starts a resize for an XWayland client's _NET_WM_MOVERESIZE,
    // but it does apply the size and position a floating client asks for. So
    // there the grips run the drag themselves: the pointer comes from Hyprland
    // (global, so unaffected by the window moving under it on west/north
    // edges), the geometry goes out as ordinary Width/Height/Position changes.

    private sealed record OwnResize(Window Window, WindowEdge Edge, Point StartCursor,
        PixelPoint StartPosition, Size StartSize, double DipsPerLogical);

    private OwnResize? _resize;

    private void BeginOwnResize(Window window, WindowEdge edge, PointerPressedEventArgs e)
    {
        var screen = window.Screens.ScreenFromWindow(window);
        if (screen == null || Hyprland.CursorPosition() is not { } cursor) return;
        var monitor = Hyprland.FocusedMonitor();
        var pixelsPerLogical = monitor != null ? Hyprland.PixelsPerLogical(screen.Bounds, monitor) : 1;
        _resize = new OwnResize(window, edge, cursor, window.Position,
            new Size(window.Width, window.Height), pixelsPerLogical / screen.Scaling);
        e.Pointer.Capture((IInputElement?)e.Source);
    }

    private void ContinueOwnResize()
    {
        if (_resize is not { } r || Hyprland.CursorPosition() is not { } cursor) return;
        var delta = (cursor - r.StartCursor) * r.DipsPerLogical;
        var w = r.Window;
        var (position, size) = Resized(r.StartPosition, r.StartSize, r.Edge, delta,
            new Size(w.MinWidth, w.MinHeight), new Size(w.MaxWidth, w.MaxHeight), w.RenderScaling);
        if (position != w.Position) w.Position = position;
        w.Width = size.Width;
        // Windows without vertical edges size their height from their width.
        if (VerticalEdges) w.Height = size.Height;
    }

    /// <summary>
    /// The window's frame after dragging <paramref name="edge"/> by
    /// <paramref name="delta"/> (DIPs), clamped to its size limits. West and
    /// north edges move the origin so the opposite edge stays put.
    /// </summary>
    internal static (PixelPoint Position, Size Size) Resized(PixelPoint startPosition, Size startSize,
        WindowEdge edge, Vector delta, Size min, Size max, double scaling)
    {
        var (west, east, north, south) = Sides(edge);
        var w = Math.Clamp(startSize.Width + (east ? delta.X : west ? -delta.X : 0), min.Width, max.Width);
        var h = Math.Clamp(startSize.Height + (south ? delta.Y : north ? -delta.Y : 0), min.Height, max.Height);
        var x = west ? startPosition.X + (int)Math.Round((startSize.Width - w) * scaling) : startPosition.X;
        var y = north ? startPosition.Y + (int)Math.Round((startSize.Height - h) * scaling) : startPosition.Y;
        return (new PixelPoint(x, y), new Size(w, h));
    }

    private static (bool West, bool East, bool North, bool South) Sides(WindowEdge edge) => edge switch
    {
        WindowEdge.NorthWest => (true, false, true, false),
        WindowEdge.North => (false, false, true, false),
        WindowEdge.NorthEast => (false, true, true, false),
        WindowEdge.West => (true, false, false, false),
        WindowEdge.East => (false, true, false, false),
        WindowEdge.SouthWest => (true, false, false, true),
        WindowEdge.South => (false, false, false, true),
        _ => (false, true, false, true),
    };

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == VerticalEdgesProperty)
            _top.IsVisible = _bottom.IsVisible = VerticalEdges;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _window = TopLevel.GetTopLevel(this) as Window;
        if (_window == null) return;
        _window.PropertyChanged += OnWindowPropertyChanged;
        UpdateVisibility();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        if (_window != null) _window.PropertyChanged -= OnWindowPropertyChanged;
        _window = null;
        base.OnDetachedFromVisualTree(e);
    }

    private void OnWindowPropertyChanged(object? sender, AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property == Window.WindowStateProperty || e.Property == Window.CanResizeProperty)
            UpdateVisibility();
    }

    private void UpdateVisibility()
        => IsVisible = _window is { CanResize: true, WindowState: WindowState.Normal };
}
