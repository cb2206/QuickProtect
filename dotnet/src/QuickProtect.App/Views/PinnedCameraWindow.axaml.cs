using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using QuickProtect.Core.Models;

namespace QuickProtect.App.Views;

/// <summary>
/// A single always-on-top floating camera window. Borderless; dragged by its
/// header or its video. Frame changes and the unpin action are reported to the manager via
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

    // Re-requests the aspect height after a resize the WM didn't apply (~3 s at most).
    private const int AspectRetryCount = 20;
    private readonly DispatcherTimer _aspectRetry = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private int _aspectRetriesLeft;

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
        _aspectRetry.Tick += OnAspectRetry;
        Closed += (_, _) => _aspectRetry.Stop();
    }

    private void OnSizeChanged(object? sender, SizeChangedEventArgs e)
    {
        // Lock height to the camera aspect, driving from width (guarded against the
        // re-entrant SizeChanged our own Height assignment triggers). A change of
        // height alone is corrected too: a corner drag on Windows ends with a resize
        // that repeats the width but carries the pointer's height, which would
        // otherwise stick and leave the video cropped.
        if (!_constraining && (e.WidthChanged || e.HeightChanged))
        {
            _aspectRetry.Stop();
            if (!ApplyAspect())
            {
                // The window manager may drop our request: mutter ignores client
                // resizes while its own interactive resize (a grip drag) is running,
                // and sends no further resize once the drag ends. Keep re-requesting
                // until the size sticks; bounded, so a WM that refuses for good
                // (tiling) doesn't get asked forever.
                _aspectRetriesLeft = AspectRetryCount;
                _aspectRetry.Start();
            }
        }
        FrameChanged?.Invoke(this);
    }

    private void OnAspectRetry(object? sender, EventArgs e)
    {
        if (ApplyAspect() || --_aspectRetriesLeft <= 0) _aspectRetry.Stop();
    }

    /// <summary>
    /// Request the aspect-locked height if the real size is off it. Returns true when
    /// the window already has it (or is maximized/fullscreen, where the WM owns the size).
    /// </summary>
    private bool ApplyAspect()
    {
        if (WindowState != WindowState.Normal) return true;
        // ClientSize is the size the WM last confirmed; Height is only what we asked
        // for, and keeps our value when the WM drops the request.
        var target = Math.Clamp(PinnedWindowGeometry.Constrain(ClientSize.Width, AspectRatio).Height,
            MinHeight, MaxHeight);
        if (Math.Abs(target - ClientSize.Height) <= 0.5) return true;

        _constraining = true;
        if (Math.Abs(target - Height) > 0.5) Height = target;
        else InvalidateMeasure(); // Height already holds the target: re-send it via layout
        _constraining = false;
        return false;
    }

    private void Move_Drag(object? sender, PointerPressedEventArgs e)
    {
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e);
    }

    private void Unpin_Click(object? sender, RoutedEventArgs e) => Unpinned?.Invoke(CameraId);

    private void Mute_Click(object? sender, RoutedEventArgs e)
        => (DataContext as ViewModels.CameraTileViewModel)?.ToggleMute();
}
