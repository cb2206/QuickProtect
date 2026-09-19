using System.ComponentModel;
using Avalonia;
using Avalonia.Threading;
using QuickProtect.App.ViewModels;
using QuickProtect.App.Views;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Owns the always-on-top pinned camera windows. Each pinned window streams
/// independently of the popover (its own player + pinned server allocation), so
/// it keeps running while the panel is closed. Persisted pins are restored when
/// the camera list loads. Port of the macOS <c>PinnedWindowManager</c>.
/// </summary>
public sealed class PinnedWindowManager
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;
    private readonly Dictionary<string, (PinnedCameraWindow window, CameraTileViewModel tile)> _open = new();

    // Frame persistence is debounced: a drag fires PositionChanged per pixel,
    // and each write rewrites the whole preferences file on the UI thread.
    private readonly HashSet<PinnedCameraWindow> _dirtyFrames = new();
    private readonly DispatcherTimer _persistTimer;

    public PinnedWindowManager(ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        _persistTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _persistTimer.Tick += (_, _) =>
        {
            _persistTimer.Stop();
            foreach (var window in _dirtyFrames) PersistFrameNow(window);
            _dirtyFrames.Clear();
        };
        // Restore persisted pins once the camera list is available.
        _service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProtectService.Cameras))
                Dispatcher.UIThread.Post(RestoreFromSettings);
        };
    }

    public bool IsPinned(string cameraId) => _open.ContainsKey(cameraId) || _settings.IsPinned(cameraId);

    /// <summary>Pin a camera: persist it and open its floating window if not already open.</summary>
    public void Pin(Camera camera)
    {
        if (_open.ContainsKey(camera.Id)) return;
        if (!_settings.IsPinned(camera.Id)) _settings.SetPinned(camera.Id);
        OpenWindow(camera, X: null, Y: null, W: null, H: null);
    }

    public void Unpin(string cameraId)
    {
        _settings.RemovePinned(cameraId);
        CloseWindow(cameraId);
    }

    /// <summary>Reconcile open windows against persisted pins and the live camera list.</summary>
    public void RestoreFromSettings()
    {
        foreach (var state in _settings.PinnedCameras())
        {
            if (_open.ContainsKey(state.CameraId)) continue;
            var camera = _service.Cameras.FirstOrDefault(c => c.Id == state.CameraId);
            if (camera == null) continue;
            OpenWindow(camera, state.X, state.Y, state.W, state.H);
        }
    }

    private void OpenWindow(Camera camera, double? X, double? Y, double? W, double? H)
    {
        var tile = new CameraTileViewModel(camera, _service, _settings, pinned: true);

        // Size from the saved frame, else default to the cached aspect ratio.
        var ar = _settings.CachedAspectRatio(camera.Id) ?? PinnedWindowGeometry.FallbackAspect;
        var size = W is { } w && H is { } h && w > 0 && h > 0
            ? new PinnedWindowGeometry.Size(w, h)
            : PinnedWindowGeometry.DefaultSize(ar);

        var window = new PinnedCameraWindow(camera.Id)
        {
            DataContext = tile,
            Width = size.Width,
            Height = size.Height,
            AspectRatio = ar
        };
        if (X is { } x && Y is { } y)
            window.Position = new PixelPoint((int)x, (int)y);

        window.Unpinned += Unpin;
        window.FrameChanged += PersistFrame;
        window.Closed += (_, _) =>
        {
            if (_open.ContainsKey(camera.Id)) CloseWindow(camera.Id);
        };

        _open[camera.Id] = (window, tile);
        // Start streaming only after the window (and its video surface) exists,
        // so the surface is subscribed before the first frame lands.
        window.Opened += (_, _) => Dispatcher.UIThread.Post(() => _ = tile.StartAsync(),
            DispatcherPriority.Background);
        window.Show();
    }

    private void PersistFrame(PinnedCameraWindow window)
    {
        _dirtyFrames.Add(window);
        _persistTimer.Stop();
        _persistTimer.Start();
    }

    private void PersistFrameNow(PinnedCameraWindow window)
    {
        if (!_settings.IsPinned(window.CameraId)) return; // don't resurrect an unpinned entry
        _settings.SetPinned(window.CameraId,
            (window.Position.X, window.Position.Y, window.Width, window.Height));
    }

    /// <summary>
    /// Tears the window down. Persistence is untouched here — callers that mean
    /// "unpin" remove the entry themselves; every other close (app exit, the
    /// user closing the window) keeps the pin so it reopens next launch.
    /// </summary>
    private void CloseWindow(string cameraId)
    {
        if (!_open.Remove(cameraId, out var entry)) return;
        entry.tile.Stop();          // releases the pinned server allocation
        entry.window.Unpinned -= Unpin;
        entry.window.FrameChanged -= PersistFrame;
        // Flush a pending frame write so the last position survives the close.
        if (_dirtyFrames.Remove(entry.window)) PersistFrameNow(entry.window);
        // Close before disposing the tile so the surface unsubscribes from a
        // still-live client.
        entry.window.Close();
        entry.tile.Dispose();
    }

    /// <summary>Tear down all pinned windows (app exit). Persistence is kept.</summary>
    public void CloseAll()
    {
        foreach (var id in _open.Keys.ToList()) CloseWindow(id);
    }
}
