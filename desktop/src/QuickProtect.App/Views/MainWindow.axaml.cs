using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using QuickProtect.App.ViewModels;
using QuickProtect.Core.Models;

namespace QuickProtect.App.Views;

public partial class MainWindow : Window
{
    // Keys currently held, so the OS key-repeat doesn't re-fire PtzPress.
    private readonly HashSet<Key> _heldKeys = new();

    public MainWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
    }

    private MainViewModel? Vm => DataContext as MainViewModel;

    // Start/stop streams as the panel is shown/hidden so a closed panel never
    // keeps server-side allocations alive (mirrors the macOS open/close cleanup).
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IsVisibleProperty && Vm is { } vm)
        {
            if (change.GetNewValue<bool>()) vm.StartAll(); else vm.StopAll();
        }
    }

    // MARK: - Focus entry / exit

    private void Tile_Focus(object? sender, RoutedEventArgs e)
    {
        if (sender is Control { DataContext: CameraTileViewModel tile }) Vm?.Focus(tile.Camera);
    }

    private void Focus_Back(object? sender, RoutedEventArgs e) => ExitFocus();

    private void ExitFocus()
    {
        if (WindowState == WindowState.FullScreen) WindowState = WindowState.Normal;
        Vm?.ExitFocus();
    }

    private void Focus_ToggleFullscreen(object? sender, RoutedEventArgs e) => ToggleFullscreen();

    private void Focus_Pin(object? sender, RoutedEventArgs e)
    {
        if (Vm?.FocusTile is { } ft) App.Instance.PinnedWindows.Pin(ft.Camera);
    }

    private void Focus_Snapshot(object? sender, RoutedEventArgs e) => CaptureSnapshot();

    private void CaptureSnapshot()
    {
        if (Vm?.FocusTile is not { } ft) return;
        var result = Services.SnapshotService.Capture(ft.Player, ft.Name);
        Vm.ShowToast(result.Message);
    }

    private void ToggleFullscreen()
        => WindowState = WindowState == WindowState.FullScreen ? WindowState.Normal : WindowState.FullScreen;

    // MARK: - PTZ d-pad (pointer hold)

    private void Dpad_Pressed(object? sender, PointerPressedEventArgs e)
    {
        if (Direction(sender) is { } d) Vm?.FocusTile?.PtzPress(d);
    }

    private void Dpad_Released(object? sender, PointerReleasedEventArgs e) => ReleaseDpad(sender);

    // Releasing on pointer-exit too, so a drag off the button stops the motion.
    private void Dpad_Exited(object? sender, PointerEventArgs e) => ReleaseDpad(sender);

    private void ReleaseDpad(object? sender)
    {
        if (Direction(sender) is { } d) Vm?.FocusTile?.PtzRelease(d);
    }

    private static PtzDirection? Direction(object? sender)
        => sender is Control { Tag: string tag } && Enum.TryParse<PtzDirection>(tag, out var d) ? d : null;

    // MARK: - Keyboard (arrows pan/tilt, I/O zoom, Esc back, F fullscreen)

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (Vm is not { } vm) return;

        if (e.Key == Key.Escape && vm.IsFocusMode) { ExitFocus(); e.Handled = true; return; }
        if (e.Key == Key.F && vm.IsFocusMode) { ToggleFullscreen(); e.Handled = true; return; }
        if (e.Key == Key.S && vm.IsFocusMode) { CaptureSnapshot(); e.Handled = true; return; }

        if (vm.FocusTile is not { } ft) return;
        if (MapKey(e.Key, ft) is not { } d) return;
        if (!_heldKeys.Add(e.Key)) { e.Handled = true; return; } // ignore key-repeat
        ft.PtzPress(d);
        e.Handled = true;
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        _heldKeys.Remove(e.Key);
        if (Vm?.FocusTile is { } ft && MapKey(e.Key, ft) is { } d)
        {
            ft.PtzRelease(d);
            e.Handled = true;
        }
    }

    private static PtzDirection? MapKey(Key key, CameraTileViewModel ft) => key switch
    {
        Key.Left when ft.IsPtz => PtzDirection.Left,
        Key.Right when ft.IsPtz => PtzDirection.Right,
        Key.Up when ft.IsPtz => PtzDirection.Up,
        Key.Down when ft.IsPtz => PtzDirection.Down,
        Key.I when ft.CanZoom => PtzDirection.ZoomIn,
        Key.O when ft.CanZoom => PtzDirection.ZoomOut,
        _ => null
    };
}
