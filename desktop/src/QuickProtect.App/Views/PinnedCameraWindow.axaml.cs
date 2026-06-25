using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;

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

    // Parameterless ctor for the Avalonia previewer / runtime XAML loader only.
    public PinnedCameraWindow() : this("") { }

    public PinnedCameraWindow(string cameraId)
    {
        CameraId = cameraId;
        InitializeComponent();
        Icon = ApertureIcon.Create(64);

        // Persist position/size as the user moves or resizes.
        PositionChanged += (_, _) => FrameChanged?.Invoke(this);
        SizeChanged += (_, _) => FrameChanged?.Invoke(this);
    }

    private void Header_Drag(object? sender, PointerPressedEventArgs e)
    {
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e);
    }

    private void Unpin_Click(object? sender, RoutedEventArgs e) => Unpinned?.Invoke(CameraId);
}
