using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
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
        // Tile drag-reorder needs tunnel handlers: the footer Button swallows
        // bubbled pointer events, and the native VideoView swallows everything.
        AddHandler(PointerPressedEvent, Tile_DragPressed, RoutingStrategies.Tunnel);
        AddHandler(PointerMovedEvent, Tile_DragMoved, RoutingStrategies.Tunnel);
        AddHandler(PointerReleasedEvent, Tile_DragReleased, RoutingStrategies.Tunnel);
        // Focus-mode hotkeys run in the tunnel phase: a control that kept keyboard
        // focus from grid mode (e.g. the search TextBox, which eats arrow keys for
        // caret movement) must never swallow PTZ/shortcut keys.
        AddHandler(KeyDownEvent, (_, e) => { if (Vm is { IsFocusMode: true }) HandleGlobalKeyDown(e); },
            RoutingStrategies.Tunnel);
        AddHandler(KeyUpEvent, (_, e) => { if (Vm is { IsFocusMode: true }) HandleGlobalKeyUp(e); },
            RoutingStrategies.Tunnel);
        // Entering focus mode pulls keyboard focus onto the focus view, so typed
        // shortcuts don't land in the (hidden) grid-header search box.
        DataContextChanged += (_, _) =>
        {
            if (Vm is { } vm)
                vm.PropertyChanged += (_, e) =>
                {
                    if (e.PropertyName == nameof(MainViewModel.IsFocusMode) && vm.IsFocusMode)
                        Avalonia.Threading.Dispatcher.UIThread.Post(() => FocusRoot.Focus());
                };
        };
        // Restore the per-profile panel size (macOS persists panel geometry).
        if (QuickProtect.Core.Services.AppSettings.Shared.PanelSize() is { } size)
        {
            Width = size.Width;
            Height = size.Height;
        }
        // Popover behavior: clicking anywhere else dismisses the panel, like the
        // macOS tray popover. Focus moving to one of our own windows or popups
        // (dropdowns, Settings) doesn't count as "outside". --no-dismiss keeps
        // the panel up for automated UI testing.
        if (!Program.LaunchArgs.Contains("--no-dismiss"))
            Deactivated += (_, _) =>
            {
                if (WindowState != WindowState.FullScreen && !ForegroundBelongsToThisProcess())
                {
                    LastAutoHide = DateTime.UtcNow;
                    Hide();
                }
            };
    }

    /// <summary>
    /// When the outside-click that dismissed the panel was the tray icon itself,
    /// the subsequent tray-click toggle must not instantly reopen it. The tray
    /// handler checks this timestamp.
    /// </summary>
    public DateTime LastAutoHide { get; private set; } = DateTime.MinValue;

    private MainViewModel? Vm => DataContext as MainViewModel;

    /// <summary>True when the newly focused window is ours (popup, Settings, …).</summary>
    private static bool ForegroundBelongsToThisProcess()
    {
        if (!OperatingSystem.IsWindows()) return false;
        var fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        _ = GetWindowThreadProcessId(fg, out var pid);
        return pid == Environment.ProcessId;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int processId);

    /// <summary>Anchor the panel to the tray corner of the primary screen.</summary>
    private void PositionNearTray()
    {
        if (WindowState == WindowState.FullScreen) return;
        var screen = Screens.Primary ?? Screens.All.FirstOrDefault();
        if (screen == null) return;
        var wa = screen.WorkingArea;
        var w = (int)Math.Round(Width * screen.Scaling);
        var h = (int)Math.Round(Height * screen.Scaling);
        // Bottom-right, above the taskbar (Windows/Linux convention; the working
        // area already excludes the taskbar on whichever edge it docks).
        Position = new PixelPoint(wa.X + wa.Width - w - 12, wa.Y + wa.Height - h - 12);
    }

    private void Header_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        // The chrome header doubles as the drag handle for the borderless panel,
        // but only when the press isn't on an interactive control.
        if (e.Source is Control c && c.FindAncestorOfType<Button>() == null
            && c.FindAncestorOfType<ComboBox>() == null && c.FindAncestorOfType<TextBox>() == null)
            BeginMoveDrag(e);
    }

    // Start/stop streams as the panel is shown/hidden so a closed panel never
    // keeps server-side allocations alive (mirrors the macOS open/close cleanup).
    // Teardown is deferred through the stream keep-alive grace (App.PanelClosed)
    // so a quick reopen re-attaches to the still-connected streams.
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IsVisibleProperty && Vm is { } vm)
        {
            if (change.GetNewValue<bool>())
            {
                App.Instance.PanelOpened();
                PositionNearTray();
                vm.StartAll();
            }
            else
            {
                QuickProtect.Core.Services.AppSettings.Shared.SetPanelSize(Width, Height);
                App.Instance.PanelClosed(vm);
            }
        }
    }

    // MARK: - Grid drag-to-reorder (pointer drag on a tile, threshold-gated so
    // plain clicks still focus the camera)

    private CameraTileViewModel? _dragTile;
    private Border? _dragVisual;
    private Point _dragStart;
    private bool _dragging;

    private static Border? TileBorderAt(object? source)
    {
        for (var c = source as Control; c != null; c = c.Parent as Control)
            if (c is Border { DataContext: CameraTileViewModel } b) return b;
        return null;
    }

    private void Tile_DragPressed(object? sender, PointerPressedEventArgs e)
    {
        if (Vm is not { IsGridMode: true }) return;
        if (TileBorderAt(e.Source) is not { DataContext: CameraTileViewModel tile } border) return;
        _dragTile = tile;
        _dragVisual = border;
        _dragStart = e.GetPosition(this);
        _dragging = false;
    }

    private void Tile_DragMoved(object? sender, PointerEventArgs e)
    {
        if (_dragTile == null || _dragging) return;
        var d = e.GetPosition(this) - _dragStart;
        if (Math.Abs(d.X) < 12 && Math.Abs(d.Y) < 12) return;
        _dragging = true;
        if (_dragVisual != null) _dragVisual.Opacity = 0.45;
    }

    private void Tile_DragReleased(object? sender, PointerReleasedEventArgs e)
    {
        var tile = _dragTile;
        var visual = _dragVisual;
        var wasDragging = _dragging;
        _dragTile = null;
        _dragVisual = null;
        _dragging = false;
        if (visual != null) visual.Opacity = 1.0;
        if (tile == null || Vm is not { } vm) return;

        if (!wasDragging)
        {
            // Plain left-click anywhere on the tile (video included — it's
            // composited now) focuses the camera, like tapping a macOS tile.
            if (e.InitialPressMouseButton == MouseButton.Left) vm.Focus(tile.Camera);
            return;
        }

        // Drop on whichever tile the pointer is over.
        var hit = this.GetVisualsAt(e.GetPosition(this))
            .Select(v => (v as Control)?.DataContext)
            .OfType<CameraTileViewModel>()
            .FirstOrDefault(t => !ReferenceEquals(t, tile));
        if (hit != null) vm.MoveTile(tile, hit);
        e.Handled = true;
    }

    // MARK: - Tile context menu (macOS grid-tile menu parity, built dynamically)

    private void Tile_ContextRequested(object? sender, ContextRequestedEventArgs e)
    {
        if (sender is not Border { DataContext: CameraTileViewModel tile } border || Vm is not { } vm) return;
        e.Handled = true;
        var flyout = new MenuFlyout();
        var items = flyout.Items;

        var fullscreen = new MenuItem { Header = Localization.Loc.Get("View fullscreen") };
        fullscreen.Click += (_, _) => { vm.Focus(tile.Camera); if (WindowState != WindowState.FullScreen) ToggleFullscreen(); };
        items.Add(fullscreen);

        var openProtect = new MenuItem { Header = Localization.Loc.Get("Open in Protect") };
        openProtect.Click += (_, _) => vm.OpenInProtect(tile);
        items.Add(openProtect);

        var pinned = App.Instance.PinnedWindows.IsPinned(tile.Camera.Id);
        var pin = new MenuItem
        {
            Header = Localization.Loc.Get(pinned ? "Unpin Floating Window" : "Pin as Floating Window")
        };
        pin.Click += (_, _) =>
        {
            if (pinned) App.Instance.PinnedWindows.Unpin(tile.Camera.Id);
            else App.Instance.PinnedWindows.Pin(tile.Camera);
        };
        items.Add(pin);

        items.Add(new Separator());

        // Size (Small / Medium / Large + reset)
        var currentSize = vm.SizeFor(tile);
        var sizeMenu = new MenuItem { Header = Localization.Loc.Get("Size") };
        foreach (var (label, size) in new[]
                 {
                     ("Small", QuickProtect.Core.Services.AppSettings.CameraSize.Small),
                     ("Medium", QuickProtect.Core.Services.AppSettings.CameraSize.Medium),
                     ("Large", QuickProtect.Core.Services.AppSettings.CameraSize.Large)
                 })
        {
            var isCurrent = currentSize == size || (currentSize == null && size == QuickProtect.Core.Services.AppSettings.CameraSize.Medium);
            var item = new MenuItem { Header = (isCurrent ? "✓ " : "   ") + Localization.Loc.Get(label) };
            var s = size;
            item.Click += (_, _) => vm.SetTileSize(tile, s);
            sizeMenu.Items.Add(item);
        }
        var resetSize = new MenuItem { Header = Localization.Loc.Get("Reset size to Auto") };
        resetSize.Click += (_, _) => vm.SetTileSize(tile, null);
        sizeMenu.Items.Add(new Separator());
        sizeMenu.Items.Add(resetSize);
        items.Add(sizeMenu);

        // Stream quality (default + explicit tiers)
        var currentQuality = vm.QualityFor(tile);
        var qualityMenu = new MenuItem { Header = Localization.Loc.Get("Stream quality") };
        var useDefault = new MenuItem
        {
            Header = (currentQuality == null ? "✓ " : "   ") +
                     string.Format(Localization.Loc.Get("Use default ({0})"), vm.DefaultQuality.RawValue())
        };
        useDefault.Click += (_, _) => vm.SetTileQuality(tile, null);
        qualityMenu.Items.Add(useDefault);
        foreach (var q in new[] { StreamQuality.Auto, StreamQuality.Low, StreamQuality.Medium, StreamQuality.High })
        {
            var item = new MenuItem { Header = (currentQuality == q ? "✓ " : "   ") + q.RawValue() };
            var quality = q;
            item.Click += (_, _) => vm.SetTileQuality(tile, quality);
            qualityMenu.Items.Add(item);
        }
        items.Add(qualityMenu);

        items.Add(new Separator());

        // Add Camera (hidden cameras in this profile)
        var hidden = vm.HiddenCameras();
        if (hidden.Count > 0)
        {
            var addMenu = new MenuItem { Header = Localization.Loc.Get("Add Camera") };
            foreach (var cam in hidden)
            {
                var item = new MenuItem { Header = cam.Name };
                var id = cam.Id;
                item.Click += (_, _) => vm.UnhideCamera(id);
                addMenu.Items.Add(item);
            }
            items.Add(addMenu);
        }

        var hide = new MenuItem { Header = Localization.Loc.Get("Hide this camera") };
        hide.Click += (_, _) => vm.HideCamera(tile);
        items.Add(hide);

        flyout.ShowAt(border, true);
    }

    // MARK: - Focus entry / exit

    private void Focus_Back(object? sender, RoutedEventArgs e) => ExitFocus();

    // MARK: - Focus-surface interactions (click back, double-click Protect,
    // drag-to-pan when zoomed, scroll pan, Ctrl+scroll digital zoom)

    private Point _focusPressPos;
    private bool _focusDragPanned;
    private CancellationTokenSource? _pendingExit;

    private void FocusSurface_PointerPressed(object? sender, PointerPressedEventArgs e)
    {
        _focusPressPos = e.GetPosition(FocusSurface);
        _focusDragPanned = false;
        if (e.ClickCount == 2)
        {
            // Double-click: open in Protect (cancels the pending single-click exit).
            _pendingExit?.Cancel();
            _pendingExit = null;
            if (Vm is { FocusTile: { } ft } vm) vm.OpenInProtect(ft);
            e.Handled = true;
        }
    }

    private void FocusSurface_PointerMoved(object? sender, PointerEventArgs e)
    {
        if (Vm?.FocusTile is not { IsDigitallyZoomed: true } ft) return;
        if (!e.GetCurrentPoint(FocusSurface).Properties.IsLeftButtonPressed) return;
        var pos = e.GetPosition(FocusSurface);
        var delta = pos - _focusPressPos;
        if (!_focusDragPanned && Math.Abs(delta.X) < 4 && Math.Abs(delta.Y) < 4) return;
        _focusDragPanned = true;
        _focusPressPos = pos;
        var bounds = FocusSurface.Bounds;
        if (bounds.Width < 1 || bounds.Height < 1) return;
        // Drag moves the image with the pointer (macOS drag-to-pan).
        ft.DigitalPan(-delta.X / bounds.Width, -delta.Y / bounds.Height);
    }

    private void FocusSurface_PointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (_focusDragPanned || e.InitialPressMouseButton != MouseButton.Left) return;
        // Single click on the video goes back to the grid (macOS tap behavior),
        // deferred briefly so a double-click can cancel it.
        _pendingExit?.Cancel();
        var cts = new CancellationTokenSource();
        _pendingExit = cts;
        _ = Task.Delay(280, cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled)
                Avalonia.Threading.Dispatcher.UIThread.Post(() => { if (Vm?.IsFocusMode == true) ExitFocus(); });
        });
    }

    private void FocusSurface_PointerWheelChanged(object? sender, PointerWheelEventArgs e)
    {
        if (Vm?.FocusTile is not { } ft) return;
        e.Handled = true;
        if (e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            // Ctrl+scroll (also what a touchpad pinch synthesizes on Windows).
            ft.DigitalZoomBy(e.Delta.Y > 0 ? 1.15 : 1 / 1.15);
        }
        else if (ft.IsDigitallyZoomed)
        {
            // Two-finger scroll pans the zoomed view (macOS scroll-to-pan).
            ft.DigitalPan(-e.Delta.X * 0.08, -e.Delta.Y * 0.08);
        }
    }

    private void Pip_Clicked(object? sender, PointerReleasedEventArgs e)
    {
        e.Handled = true;
        Vm?.SwapSecondary();
    }

    /// <summary>Grid viewport resize → reflow tile spans (macOS GeometryReader).</summary>
    private void GridScroll_SizeChanged(object? sender, SizeChangedEventArgs e)
        => Vm?.SetGridWidth(e.NewSize.Width);

    /// <summary>PiP sizing: ~26% of the focus width, 4:3, like macOS.</summary>
    private void FocusRoot_SizeChanged(object? sender, SizeChangedEventArgs e)
    {
        var w = Math.Max(120, e.NewSize.Width * 0.26);
        PipBorder.Width = w;
        PipBorder.Height = w * 0.75 + 22; // + label row
    }

    // MARK: - Header actions

    private void Header_Settings(object? sender, RoutedEventArgs e) => App.Instance.ShowSettings();

    private void Header_Quit(object? sender, RoutedEventArgs e) => App.Instance.RequestShutdown();

    private async void Header_SaveProfile(object? sender, RoutedEventArgs e)
    {
        var name = await NamePromptWindow.ShowAsync(this,
            Localization.Loc.Get("Save Current View as New Profile…"));
        if (!string.IsNullOrWhiteSpace(name)) Vm?.SaveCurrentViewAsProfile(name!);
    }

    private void ExitFocus()
    {
        if (WindowState == WindowState.FullScreen) WindowState = WindowState.Normal;
        ShowHud(stopTimer: true);
        Vm?.ExitFocus();
    }

    private void Focus_ToggleFullscreen(object? sender, RoutedEventArgs e) => ToggleFullscreen();

    private void Focus_Pin(object? sender, RoutedEventArgs e)
    {
        if (Vm?.FocusTile is { } ft) App.Instance.PinnedWindows.Pin(ft.Camera);
    }

    private void Focus_Snapshot(object? sender, RoutedEventArgs e) => CaptureSnapshot();

    private void Focus_Mute(object? sender, RoutedEventArgs e) => Vm?.FocusTile?.ToggleMute();

    private void Focus_SwapPip(object? sender, RoutedEventArgs e) => Vm?.SwapSecondary();

    private void Focus_Fill(object? sender, RoutedEventArgs e) => Vm?.FocusTile?.ToggleFill();

    private async void CaptureSnapshot()
    {
        if (Vm?.FocusTile is not { } ft) return;
        var result = await Services.SnapshotService.CaptureAsync(ft);
        Vm?.ShowToast(result.Message);
    }

    private void ToggleFullscreen()
    {
        WindowState = WindowState == WindowState.FullScreen ? WindowState.Normal : WindowState.FullScreen;
        if (WindowState == WindowState.FullScreen) { RestartHudTimer(); StartCursorPoll(); }
        else { ShowHud(stopTimer: true); _cursorPoll?.Stop(); }
    }

    // MARK: - Fullscreen HUD (auto-hides the focus chrome after a few idle seconds)
    //
    // Pointer wake-up needs a global cursor poll: mouse moves over the native
    // libVLC child window never reach Avalonia, so OnPointerMoved alone can't
    // resurface the chrome. Windows polls GetCursorPos; elsewhere keys still work.

    private Avalonia.Threading.DispatcherTimer? _hudTimer;
    private Avalonia.Threading.DispatcherTimer? _cursorPoll;
    private (int X, int Y) _lastCursor;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetCursorPos(out System.Drawing.Point p);

    private void StartCursorPoll()
    {
        if (!OperatingSystem.IsWindows()) return;
        _cursorPoll ??= new Avalonia.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _cursorPoll.Tick -= CursorPoll_Tick;
        _cursorPoll.Tick += CursorPoll_Tick;
        GetCursorPos(out var p);
        _lastCursor = (p.X, p.Y);
        _cursorPoll.Start();
    }

    private void CursorPoll_Tick(object? sender, EventArgs e)
    {
        if (WindowState != WindowState.FullScreen) { _cursorPoll?.Stop(); return; }
        GetCursorPos(out var p);
        var moved = Math.Abs(p.X - _lastCursor.X) > 4 || Math.Abs(p.Y - _lastCursor.Y) > 4;
        _lastCursor = (p.X, p.Y);
        if (moved && Vm is { ChromeVisible: false }) ShowHud();
    }

    private void RestartHudTimer()
    {
        _hudTimer ??= new Avalonia.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(3)
        };
        _hudTimer.Tick -= HudTimer_Tick;
        _hudTimer.Tick += HudTimer_Tick;
        _hudTimer.Stop();
        _hudTimer.Start();
    }

    private void HudTimer_Tick(object? sender, EventArgs e)
    {
        _hudTimer?.Stop();
        if (WindowState == WindowState.FullScreen && Vm is { IsFocusMode: true } vm)
            vm.ChromeVisible = false;
    }

    private void ShowHud(bool stopTimer = false)
    {
        if (Vm is { } vm) vm.ChromeVisible = true;
        if (stopTimer) _hudTimer?.Stop();
        else if (WindowState == WindowState.FullScreen) RestartHudTimer();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (WindowState == WindowState.FullScreen) ShowHud();
    }

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
        HandleGlobalKeyDown(e);
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        HandleGlobalKeyUp(e);
    }

    private void HandleGlobalKeyDown(KeyEventArgs e)
    {
        if (e.Handled) return;
        if (WindowState == WindowState.FullScreen) ShowHud();
        if (Vm is not { } vm) return;

        if (e.Key == Key.Escape && vm.IsFocusMode) { ExitFocus(); e.Handled = true; return; }
        if (e.Key == Key.Escape) { Hide(); e.Handled = true; return; } // dismiss the popover
        if (e.Key == Key.F && vm.IsFocusMode) { ToggleFullscreen(); e.Handled = true; return; }
        if (e.Key == Key.S && vm.IsFocusMode) { CaptureSnapshot(); e.Handled = true; return; }
        if (e.Key == Key.M && vm.IsFocusMode) { vm.FocusTile?.ToggleMute(); e.Handled = true; return; }
        if (e.Key == Key.C && vm.IsFocusMode) { vm.SwapSecondary(); e.Handled = true; return; }

        if (vm.FocusTile is not { } ft) return;

        // Digital zoom (crop-based, 1–8× like the macOS pinch zoom): +/- zoom,
        // 0 resets. Panning uses the arrows — plain arrows on non-PTZ cameras,
        // Shift+arrows on PTZ cameras (whose plain arrows drive the mount).
        switch (e.Key)
        {
            case Key.OemPlus or Key.Add: ft.DigitalZoomIn(); e.Handled = true; return;
            case Key.OemMinus or Key.Subtract: ft.DigitalZoomOut(); e.Handled = true; return;
            case Key.D0 or Key.NumPad0: ft.DigitalZoomReset(); e.Handled = true; return;
        }
        if (ft.IsDigitallyZoomed && (!ft.IsPtz || e.KeyModifiers.HasFlag(KeyModifiers.Shift)))
        {
            const double step = 0.15; // fraction of the visible window per key press
            var panned = e.Key switch
            {
                Key.Left => (Vector?)new Vector(-step, 0),
                Key.Right => new Vector(step, 0),
                Key.Up => new Vector(0, -step),
                Key.Down => new Vector(0, step),
                _ => null
            };
            if (panned is { } p) { ft.DigitalPan(p.X, p.Y); e.Handled = true; return; }
        }

        if (MapKey(e.Key, ft) is not { } d) return;
        if (!_heldKeys.Add(e.Key)) { e.Handled = true; return; } // ignore key-repeat
        ft.PtzPress(d);
        e.Handled = true;
    }

    private void HandleGlobalKeyUp(KeyEventArgs e)
    {
        if (!_heldKeys.Remove(e.Key)) return; // not a key we pressed (or tunnel already released it)
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
