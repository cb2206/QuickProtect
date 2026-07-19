using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using QuickProtect.Core.Models;

namespace QuickProtect.App.Views;

/// <summary>
/// A single always-on-top floating camera window. Borderless; dragged by its
/// header. Frame changes and the unpin action are reported to the manager via
/// callbacks (the window doesn't know about persistence).
/// </summary>
public partial class PinnedCameraWindow : Window
{
    public string CameraId { get; }
    public event Action<string>? Unpinned;
    public event Action<PinnedCameraWindow>? FrameChanged;

    /// <summary>Camera aspect ratio (w/h) used to lock proportions on resize.</summary>
    public double AspectRatio { get; set; } = PinnedWindowGeometry.FallbackAspect;
    private bool _constraining;

    // Parameterless ctor for the Avalonia previewer / runtime XAML loader only.
    public PinnedCameraWindow() : this("") { }

    public PinnedCameraWindow(string cameraId)
    {
        CameraId = cameraId;
        InitializeComponent();
        Icon = ApertureIcon.Create(64);

        // Persist position/size as the user moves or resizes.
        PositionChanged += (_, _) => FrameChanged?.Invoke(this);
        SizeChanged += OnSizeChanged;
    }

    private void OnSizeChanged(object? sender, SizeChangedEventArgs e)
    {
        // Lock height to the camera aspect, driving from width (guarded against the
        // re-entrant SizeChanged our own Height assignment triggers).
        if (!_constraining && e.WidthChanged)
        {
            var size = PinnedWindowGeometry.Constrain(Width, AspectRatio);
            if (Math.Abs(size.Height - Height) > 0.5)
            {
                _constraining = true;
                Height = size.Height;
                _constraining = false;
            }
        }
        FrameChanged?.Invoke(this);
    }

    private void Header_Drag(object? sender, PointerPressedEventArgs e)
    {
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e);
    }

    private void Unpin_Click(object? sender, RoutedEventArgs e) => Unpinned?.Invoke(CameraId);

    private void Mute_Click(object? sender, RoutedEventArgs e)
        => (DataContext as ViewModels.CameraTileViewModel)?.ToggleMute();
}
