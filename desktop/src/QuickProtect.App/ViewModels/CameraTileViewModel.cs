using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using QuickProtect.App.Video;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// One camera tile: owns its <see cref="VideoStreamClient"/>, requests an
/// on-demand RTSP stream from the controller, and plays it through the FFmpeg
/// engine. Tracks the quality it actually got so the allocation can be released
/// on stop.
/// </summary>
public sealed partial class CameraTileViewModel : ObservableObject, IDisposable
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;

    public Camera Camera { get; private set; }

    /// <summary>The stream client, or null when the video engine is unavailable.</summary>
    public VideoStreamClient? Client { get; }

    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isOnline;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isFocused;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _fillMode;
    [ObservableProperty] private double _tileWidth;
    [ObservableProperty] private double _tileHeight;
    /// <summary>True when the video engine couldn't initialize (tile shows a notice).</summary>
    [ObservableProperty] private bool _videoUnavailable;
    /// <summary>False when filtered out by the header search box.</summary>
    [ObservableProperty] private bool _matchesSearch = true;

    // Digital zoom viewport (bound by VideoSurface; Core math in DigitalZoom).
    [ObservableProperty] private double _zoom = 1.0;
    [ObservableProperty] private double _zoomCenterX = 0.5;
    [ObservableProperty] private double _zoomCenterY = 0.5;
    [ObservableProperty] private string? _digitalZoomLabel;

    private readonly DigitalZoom _digitalZoom = new();
    private string? _activeQuality;
    private string? _activeUrl;
    private bool _starting;
    private readonly bool _pinned;
    private string? _fixedQuality;

    /// <param name="pinned">
    /// When true the tile drives a pinned floating window: it uses the pinned
    /// server-side allocation lifecycle and always streams at high quality.
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

        if (FfmpegEngine.IsAvailable)
        {
            Client = new VideoStreamClient();
            Client.StateChanged += state => Dispatcher.UIThread.Post(() =>
            {
                IsPlaying = state == VideoState.Playing;
                if (state is VideoState.Playing or VideoState.Failed) IsLoading = false;
            });
            // Learn the real frame size for aspect-dependent UI (pinned windows,
            // grid tile aspect) — macOS caches decoder dimensions the same way.
            Client.VideoSizeKnown += (w, h) => _settings.CacheVideoDimensions((uint)w, (uint)h, Camera.Id);
        }
        else
        {
            _videoUnavailable = true;
        }
    }

    // MARK: - Audio mute (audio output lands with the engine's audio sink; the
    // preference is kept so the UI and settings stay wired).

    public void ToggleMute()
    {
        IsMuted = !IsMuted;
        _settings.SpeakerEnabled = !IsMuted;
    }

    /// <summary>Toggle fit (letterbox) vs. fill (crop); rendered by VideoSurface.</summary>
    public void ToggleFill()
    {
        FillMode = !FillMode;
        _settings.SetCameraFillMode(FillMode, Camera.Id);
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

    public void PtzPress(PtzDirection d) => Send(PtzMapping.Press(d));
    public void PtzRelease(PtzDirection d) => Send(PtzMapping.Release(d));
    private void Send(PtzMapping.Axes a) => _service.PtzSetAxes(Camera.Id, a.Pan, a.Tilt, a.Zoom);
    public void PtzStopAll() => _service.PtzStopAll(Camera.Id);

    // MARK: - Digital zoom (crop-window math in Core's DigitalZoom)

    public bool IsDigitallyZoomed => _digitalZoom.IsZoomed;

    public void DigitalZoomIn() { _digitalZoom.ZoomIn(); ApplyDigitalZoom(); }
    public void DigitalZoomOut() { _digitalZoom.ZoomOut(); ApplyDigitalZoom(); }
    public void DigitalZoomReset() { _digitalZoom.Reset(); ApplyDigitalZoom(); }
    public void DigitalZoomBy(double factor) { _digitalZoom.SetZoom(_digitalZoom.Zoom * factor); ApplyDigitalZoom(); }

    /// <summary>Pan the zoomed view by a fraction of the visible window.</summary>
    public void DigitalPan(double dx, double dy) { _digitalZoom.Pan(dx, dy); ApplyDigitalZoom(); }

    private void ApplyDigitalZoom()
    {
        Zoom = _digitalZoom.Zoom;
        ZoomCenterX = _digitalZoom.CenterX;
        ZoomCenterY = _digitalZoom.CenterY;
        DigitalZoomLabel = _digitalZoom.IsZoomed ? $"{_digitalZoom.Zoom:0.#}×" : null;
    }

    // MARK: - Stream lifecycle

    /// <summary>Resolve the effective quality for the current view state and start playback.</summary>
    public async Task StartAsync()
    {
        if (Client == null || _starting || !Camera.IsOnline) return;
        if (Client.State is VideoState.Playing or VideoState.Connecting) return;
        _starting = true;
        if (!Client.HasFrame) IsLoading = true;
        try
        {
            var gridIsLarge = _settings.SizeFor(Camera.Id) == AppSettings.CameraSize.Large;
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

            Client.Start(FfmpegEngine.MapUrl(r.url));
        }
        catch (Exception ex)
        {
            Log.Line($"[Tile] start failed for {Camera.Name}: {ex.Message}");
            IsLoading = false;
        }
        finally { _starting = false; }
    }

    /// <summary>
    /// PiP swap: exchange live playback with <paramref name="other"/>. Both
    /// clients switch to each other's URL in place, keeping their last frames —
    /// server allocations stay put (their ownership swaps with the URLs).
    /// </summary>
    public void SwapPlaybackWith(CameraTileViewModel other)
    {
        if (Client == null || other.Client == null) return;
        (_activeQuality, other._activeQuality) = (other._activeQuality, _activeQuality);
        (_activeUrl, other._activeUrl) = (other._activeUrl, _activeUrl);
        (_fixedQuality, other._fixedQuality) = (other._fixedQuality, _fixedQuality);
        if (_activeUrl is { } mine) Client.SwitchUrl(FfmpegEngine.MapUrl(mine));
        if (other._activeUrl is { } theirs) other.Client.SwitchUrl(FfmpegEngine.MapUrl(theirs));
    }

    public void Stop()
    {
        Client?.Stop();
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
        Client?.Dispose();
    }
}
