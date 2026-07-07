using CommunityToolkit.Mvvm.ComponentModel;
using LibVLCSharp.Shared;
using QuickProtect.App.Services;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// One camera tile in the grid: owns its <see cref="MediaPlayer"/>, requests an
/// on-demand RTSP stream from the controller, and plays it. Tracks the quality it
/// actually got so the allocation can be released on stop.
/// </summary>
public sealed partial class CameraTileViewModel : ObservableObject, IDisposable
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;

    public Camera Camera { get; private set; }

    /// <summary>The video player, or null when libVLC is unavailable (video disabled).</summary>
    public MediaPlayer? Player { get; }

    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isOnline;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isFocused;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _fillMode;
    [ObservableProperty] private double _tileWidth;
    [ObservableProperty] private double _tileHeight;
    /// <summary>True when libVLC couldn't initialize, so the tile shows a notice instead of video.</summary>
    [ObservableProperty] private bool _videoUnavailable;
    /// <summary>False when filtered out by the header search box.</summary>
    [ObservableProperty] private bool _matchesSearch = true;

    private string? _activeQuality;
    private string? _activeUrl;
    private bool _starting;
    private readonly bool _pinned;
    private string? _fixedQuality;

    /// <param name="pinned">
    /// When true the tile drives a pinned floating window: it uses the pinned
    /// server-side allocation lifecycle (created/released independently of the
    /// popover's streams) and always streams at high quality.
    /// </param>
    /// <param name="fixedQuality">
    /// When set (e.g. "package"), the tile streams exactly this quality instead of
    /// resolving from settings — used for the secondary-lens picture-in-picture.
    /// </param>
    public CameraTileViewModel(Camera camera, ProtectService service, AppSettings settings,
                               bool pinned = false, string? fixedQuality = null)
    {
        _service = service;
        _settings = settings;
        _pinned = pinned;
        _fixedQuality = fixedQuality;
        Camera = camera;
        _name = camera.Name;
        _isOnline = camera.IsOnline;
        _isMuted = !settings.SpeakerEnabled;
        _fillMode = settings.CameraFillMode(camera.Id) ?? false;
        // Grid tile size from the active profile (small/medium/large).
        var baseWidth = settings.SizeFor(camera.Id) switch
        {
            AppSettings.CameraSize.Small => 180.0,
            AppSettings.CameraSize.Large => 380.0,
            _ => 240.0
        };
        _tileWidth = baseWidth;
        _tileHeight = Math.Round(baseWidth * 0.66);

        if (VlcManager.Shared.LibVLC is { } libvlc)
        {
            Player = new MediaPlayer(libvlc) { EnableHardwareDecoding = true };
            Player.Playing += (_, _) =>
            {
                IsPlaying = true;
                IsLoading = false;
                ApplyMute();
                ApplyFill();
            };
            Player.EncounteredError += (_, _) => IsLoading = false;
            Player.Stopped += (_, _) => IsPlaying = false;
            // Learn the real frame size once the video output exists, so fill-mode
            // crop and pinned-window aspect use the camera's true aspect ratio
            // (macOS caches this from its decoder, RTSPClient.swift).
            Player.Vout += (_, _) =>
            {
                uint w = 0, h = 0;
                if (Player.Size(0, ref w, ref h) && w > 0 && h > 0)
                {
                    _settings.CacheVideoDimensions(w, h, Camera.Id);
                    ApplyFill();
                }
            };
        }
        else
        {
            _videoUnavailable = true;
        }
    }

    // MARK: - Audio mute / fit-fill (applied to the player; persisted to settings)

    /// <summary>Toggle audio. Persists the global speaker preference (default muted).</summary>
    public void ToggleMute()
    {
        IsMuted = !IsMuted;
        _settings.SpeakerEnabled = !IsMuted;
        ApplyMute();
    }

    private void ApplyMute() { if (Player != null) Player.Mute = IsMuted; }

    /// <summary>Toggle fit (letterbox) vs. fill (crop) for the focused frame.</summary>
    public void ToggleFill()
    {
        FillMode = !FillMode;
        _settings.SetCameraFillMode(FillMode, Camera.Id);
        ApplyFill();
    }

    private void ApplyFill()
    {
        if (Player == null) return;
        // Digital zoom owns the crop while active; fill re-applies on zoom reset.
        if (_digitalZoom.IsZoomed) return;
        // Fill crops to the camera's aspect so the frame is filled; fit lets libVLC
        // letterbox (Scale 0 = auto-fit). Best-effort — tuned on-device.
        if (FillMode)
        {
            var ar = _settings.CachedAspectRatio(Camera.Id);
            Player.CropGeometry = ar is { } r && r > 0 ? $"{(int)Math.Round(r * 1000)}:1000" : null;
        }
        else
        {
            Player.CropGeometry = null;
            Player.Scale = 0;
        }
    }

    // MARK: - Digital zoom (focus view; crop-based, Core math in DigitalZoom)

    private readonly DigitalZoom _digitalZoom = new();

    /// <summary>Digital zoom factor label ("2.5×"), or null at 1× (hides the badge).</summary>
    [ObservableProperty] private string? _digitalZoomLabel;

    public bool IsDigitallyZoomed => _digitalZoom.IsZoomed;

    public void DigitalZoomIn() { _digitalZoom.ZoomIn(); ApplyDigitalZoom(); }
    public void DigitalZoomOut() { _digitalZoom.ZoomOut(); ApplyDigitalZoom(); }
    public void DigitalZoomReset() { _digitalZoom.Reset(); ApplyDigitalZoom(); }

    /// <summary>Pan the zoomed view by a fraction of the visible window.</summary>
    public void DigitalPan(double dx, double dy) { _digitalZoom.Pan(dx, dy); ApplyDigitalZoom(); }

    private void ApplyDigitalZoom()
    {
        if (Player == null) return;
        if (_digitalZoom.IsZoomed)
        {
            uint w = 0, h = 0;
            if (Player.Size(0, ref w, ref h))
                Player.CropGeometry = _digitalZoom.CropGeometry(w, h);
            DigitalZoomLabel = $"{_digitalZoom.Zoom:0.#}×";
        }
        else
        {
            DigitalZoomLabel = null;
            Player.CropGeometry = null;
            ApplyFill(); // restore the fit/fill preference
        }
    }

    public void UpdateFrom(Camera camera)
    {
        Camera = camera;
        Name = camera.Name;
        IsOnline = camera.IsOnline;
    }

    public bool IsPtz => Camera.IsPtz;
    public bool CanZoom => Camera.CanZoom;

    public void SetFocused(bool focused) => IsFocused = focused;

    // MARK: - PTZ (direction → axis mapping lives in Core's PtzMapping)

    /// <summary>Start moving along the given direction (pointer-down / key-down).</summary>
    public void PtzPress(PtzDirection d) => Send(PtzMapping.Press(d));

    /// <summary>Stop the axis the direction belongs to (pointer-up / key-up).</summary>
    public void PtzRelease(PtzDirection d) => Send(PtzMapping.Release(d));

    private void Send(PtzMapping.Axes a) => _service.PtzSetAxes(Camera.Id, a.Pan, a.Tilt, a.Zoom);

    public void PtzStopAll() => _service.PtzStopAll(Camera.Id);

    /// <summary>Resolve the effective quality for the current view state and start playback.</summary>
    public async Task StartAsync()
    {
        if (Player == null || _starting || Player.IsPlaying || !Camera.IsOnline) return;
        _starting = true;
        IsLoading = true;
        try
        {
            var gridIsLarge = _settings.SizeFor(Camera.Id) == AppSettings.CameraSize.Large;
            // A fixed quality (secondary lens) bypasses resolution; otherwise pinned
            // and focused views both run at high quality.
            var quality = _fixedQuality
                ?? _settings.EffectiveStreamQuality(Camera.Id)
                    .Resolve(focused: IsFocused || _pinned, gridIsLarge: gridIsLarge)
                    .ApiValue();

            var result = _pinned
                ? await _service.CreatePinnedStreamUrlAsync(Camera, quality)
                : await _service.CreateRtspStreamUrlAsync(Camera, quality);
            if (result is not { } r) { IsLoading = false; return; }
            _activeQuality = r.quality;
            _activeUrl = r.url;

            using var media = VlcManager.Shared.MakeMedia(r.url);
            if (media == null) { IsLoading = false; return; }
            Player.Play(media);
        }
        catch (Exception ex)
        {
            Log.Line($"[Tile] start failed for {Camera.Name}: {ex.Message}");
            IsLoading = false;
        }
        finally { _starting = false; }
    }

    /// <summary>
    /// PiP swap: exchange live playback with <paramref name="other"/>. The two
    /// players replay each other's stream URL, so the enlarged view shows the
    /// other lens instantly — server-side allocations stay put (their ownership
    /// swaps with the URLs), and no VideoView needs to re-attach.
    /// </summary>
    public void SwapPlaybackWith(CameraTileViewModel other)
    {
        if (Player == null || other.Player == null) return;
        (_activeQuality, other._activeQuality) = (other._activeQuality, _activeQuality);
        (_activeUrl, other._activeUrl) = (other._activeUrl, _activeUrl);
        (_fixedQuality, other._fixedQuality) = (other._fixedQuality, _fixedQuality);
        Replay();
        other.Replay();
    }

    private void Replay()
    {
        if (Player == null || _activeUrl is not { } url) return;
        using var media = VlcManager.Shared.MakeMedia(url);
        if (media != null) { IsLoading = true; Player.Play(media); }
    }

    /// <summary>
    /// Restart playback on the existing stream URL. Needed after the tile's
    /// native video surface is recreated (grid drag-reorder moves the item
    /// container) — libVLC only honors a new Hwnd on the next play.
    /// </summary>
    public void RestartPlayback() => Replay();

    public void Stop()
    {
        if (Player is { IsPlaying: true }) Player.Stop();
        if (_activeQuality is { } q)
        {
            if (_pinned) _service.ReleasePinnedStream(Camera.Id, q);
            else _service.ReleaseStream(Camera.Id, q);
            _activeQuality = null;
            _activeUrl = null;
        }
        IsPlaying = false;
        IsLoading = false;
    }

    public void Dispose()
    {
        Stop();
        Player?.Dispose();
    }
}
