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

    public PinnedWindowManager(ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
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
        CloseWindow(cameraId, keepPersistence: false);
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
            Height = size.Height
        };
        if (X is { } x && Y is { } y)
            window.Position = new PixelPoint((int)x, (int)y);

        window.Unpinned += Unpin;
        window.FrameChanged += PersistFrame;
        window.Closed += (_, _) =>
        {
            if (_open.ContainsKey(camera.Id)) CloseWindow(camera.Id, keepPersistence: true);
        };

        _open[camera.Id] = (window, tile);
        window.Show();
        _ = tile.StartAsync();
    }

    private void PersistFrame(PinnedCameraWindow window)
    {
        if (!_settings.IsPinned(window.CameraId)) return; // don't resurrect an unpinned entry
        _settings.SetPinned(window.CameraId,
            (window.Position.X, window.Position.Y, window.Width, window.Height));
    }

    private void CloseWindow(string cameraId, bool keepPersistence)
    {
        if (!_open.Remove(cameraId, out var entry)) return;
        entry.tile.Stop();          // releases the pinned server allocation
        entry.tile.Dispose();
        entry.window.Unpinned -= Unpin;
        entry.window.FrameChanged -= PersistFrame;
        entry.window.Close();
        // keepPersistence: pins survive so the window reopens next launch.
    }

    /// <summary>Tear down all pinned windows (app exit). Persistence is kept.</summary>
    public void CloseAll()
    {
        foreach (var id in _open.Keys.ToList()) CloseWindow(id, keepPersistence: true);
    }
}
