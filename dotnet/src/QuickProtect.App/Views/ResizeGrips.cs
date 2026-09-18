using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

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
            window.BeginResizeDrag(edge, e);
            e.Handled = true;
        };
        Children.Add(grip);
        return grip;
    }

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
