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

    /// <summary>
    /// The shared stream client (owned by the coordinator), or null when the
    /// video engine is unavailable or the tile hasn't started yet. Observable so
    /// the bound <see cref="VideoSurface"/> follows PiP swaps.
    /// </summary>
    [ObservableProperty] private VideoStreamClient? _client;
    private VideoStreamCoordinator.Handle? _handle;
    private Action<VideoState>? _stateHandler;
    private Action<int, int>? _sizeHandler;
    private Action<bool>? _audioHandler;

    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isOnline;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isFocused;
    [ObservableProperty] private bool _isMuted;
    /// <summary>True when the stream carries an audio track (shows the mute UI).</summary>
    [ObservableProperty] private bool _hasAudio;
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
        // Pinned windows always start muted with a window-local toggle (macOS
        // behavior); everywhere else mute mirrors the global speaker preference.
        _isMuted = pinned || !settings.SpeakerEnabled;
        _fillMode = settings.CameraFillMode(camera.Id) ?? false;

        _videoUnavailable = !FfmpegEngine.IsAvailable;
    }

    // MARK: - Grid sizing (macOS row-packed grid: 4 logical columns)

    /// <summary>Gap between tiles and around the grid (macOS spacing).</summary>
    public const double GridSpacing = 2.0;
    private const int ColumnCount = 4;

    private double _lastGridWidth;

    /// <summary>Column span from the active profile: Small=1, Medium=2 (default), Large=4.</summary>
    public int GridSpan => (int?)_settings.SizeFor(Camera.Id) ?? 2;

    /// <summary>
    /// Size the tile for a grid of <paramref name="gridWidth"/>: width is the
    /// camera's column span, height follows the cached stream aspect ratio
    /// (16:9 until the first frame arrives) — the macOS cellWidth/gridAspect math.
    /// </summary>
    public void ApplyTileSize(double gridWidth)
    {
        if (gridWidth <= 0) return;
        _lastGridWidth = gridWidth;
        // Outer padding + 3 inter-column gaps; each tile carries a 1px margin,
        // and 0.5px slack absorbs float rounding in the wrap layout.
        var colWidth = (gridWidth - GridSpacing * 2 - GridSpacing * (ColumnCount - 1) - 0.5) / ColumnCount;
        if (colWidth <= 0) return;
        var span = GridSpan;
        var width = span * colWidth + (span - 1) * GridSpacing;
        TileWidth = width;
        TileHeight = width / (_settings.CachedAspectRatio(Camera.Id) ?? 16.0 / 9.0);
    }

    private void SubscribeClient(VideoStreamClient client)
    {
        _stateHandler = state => Dispatcher.UIThread.Post(() =>
        {
            IsPlaying = state == VideoState.Playing;
            if (state is VideoState.Playing or VideoState.Failed) IsLoading = false;
        });
        // Learn the real frame size for aspect-dependent UI (pinned windows,
        // grid tile aspect) — macOS caches decoder dimensions the same way.
        _sizeHandler = (w, h) => Dispatcher.UIThread.Post(() =>
        {
            _settings.CacheVideoDimensions((uint)w, (uint)h, Camera.Id);
            ApplyTileSize(_lastGridWidth); // tile height follows the real aspect
        });
        _audioHandler = has => Dispatcher.UIThread.Post(() => HasAudio = has);
        client.StateChanged += _stateHandler;
        client.VideoSizeKnown += _sizeHandler;
        client.HasAudioChanged += _audioHandler;
        HasAudio = client.HasAudio;
    }

    private void UnsubscribeClient(VideoStreamClient client)
    {
        if (_stateHandler != null) client.StateChanged -= _stateHandler;
        if (_sizeHandler != null) client.VideoSizeKnown -= _sizeHandler;
        if (_audioHandler != null) client.HasAudioChanged -= _audioHandler;
        _stateHandler = null;
        _sizeHandler = null;
        _audioHandler = null;
    }

    // MARK: - Audio (rendered by the engine's platform sink; macOS parity:
    // only the focused stream and pinned windows are audio-active).

    public void ToggleMute()
    {
        IsMuted = !IsMuted;
        // A pinned window's mute is window-local; focus mute is the global
        // speaker preference (macOS toggleMute vs. PinnedCameraWindow).
        if (!_pinned) _settings.SpeakerEnabled = !IsMuted;
        Client?.SetMuted(IsMuted);
    }

    /// <summary>Route audio to this tile's client iff it is the focused or pinned view.</summary>
    private void ApplyAudioRouting()
    {
        if (Client is not { } client) return;
        client.SetMuted(IsMuted);
        client.SetAudioActive(IsFocused || _pinned);
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
        // Re-read profile-dependent size (context-menu size change, profile switch)
        // and capability flags (PTZ enrichment lands after the initial fetch).
        ApplyTileSize(_lastGridWidth);
        OnPropertyChanged(nameof(IsPtz));
        OnPropertyChanged(nameof(CanZoom));
    }

    public bool IsPtz => Camera.IsPtz;
    public bool CanZoom => Camera.CanZoom;

    public void SetFocused(bool focused) => IsFocused = focused;

    // MARK: - PTZ (direction → axis mapping lives in Core's PtzMapping)

    // Directions currently driven (keyboard or pointer), so the on-screen d-pad
    // and zoom pill light the matching button — macOS DpadButton's lit state.
    private readonly HashSet<PtzDirection> _ptzActive = new();
    public bool PtzUpActive => _ptzActive.Contains(PtzDirection.Up);
    public bool PtzDownActive => _ptzActive.Contains(PtzDirection.Down);
    public bool PtzLeftActive => _ptzActive.Contains(PtzDirection.Left);
    public bool PtzRightActive => _ptzActive.Contains(PtzDirection.Right);
    public bool PtzZoomInActive => _ptzActive.Contains(PtzDirection.ZoomIn);
    public bool PtzZoomOutActive => _ptzActive.Contains(PtzDirection.ZoomOut);

    private void RaisePtzActive()
    {
        OnPropertyChanged(nameof(PtzUpActive));
        OnPropertyChanged(nameof(PtzDownActive));
        OnPropertyChanged(nameof(PtzLeftActive));
        OnPropertyChanged(nameof(PtzRightActive));
        OnPropertyChanged(nameof(PtzZoomInActive));
        OnPropertyChanged(nameof(PtzZoomOutActive));
    }

    public void PtzPress(PtzDirection d)
    {
        if (_ptzActive.Add(d)) RaisePtzActive();
        Send(PtzMapping.Press(d));
    }

    public void PtzRelease(PtzDirection d)
    {
        if (_ptzActive.Remove(d)) RaisePtzActive();
        Send(PtzMapping.Release(d));
    }

    private void Send(PtzMapping.Axes a)
    {
        if (IsPtz || CanZoom) _service.PtzSetAxes(Camera.Id, a.Pan, a.Tilt, a.Zoom);
    }

    /// <summary>Stop motion on focus exit — only for cameras that can move at all
    /// (a stop for a fixed camera would just trigger a pointless classic login).</summary>
    public void PtzStopAll()
    {
        if (_ptzActive.Count > 0) { _ptzActive.Clear(); RaisePtzActive(); }
        if (IsPtz || CanZoom) _service.PtzStopAll(Camera.Id);
    }

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

    // MARK: - Stream lifecycle (shared clients via the coordinator)

    /// <summary>Resolve the effective quality for the current view state and start playback.</summary>
    public Task StartAsync()
    {
        if (!FfmpegEngine.IsAvailable || !Camera.IsOnline) return Task.CompletedTask;

        var gridIsLarge = _settings.SizeFor(Camera.Id) == AppSettings.CameraSize.Large;
        var quality = _fixedQuality
            ?? _settings.EffectiveStreamQuality(Camera.Id)
                .Resolve(focused: IsFocused || _pinned, gridIsLarge: gridIsLarge)
                .ApiValue();

        if (_handle is { } existing)
        {
            existing.SetDesiredQuality(quality);
            ApplyAudioRouting();
            return Task.CompletedTask;
        }

        var handle = App.Instance.Streams.Acquire(Camera, quality, lens: _fixedQuality, pinned: _pinned);
        _handle = handle;
        SubscribeClient(handle.Client);
        Client = handle.Client;
        ApplyAudioRouting();
        if (!handle.Client.HasFrame) IsLoading = true;
        IsPlaying = handle.Client.State == VideoState.Playing;
        return Task.CompletedTask;
    }

    /// <summary>
    /// PiP swap: the two tiles trade stream handles and clients (both streams
    /// keep running, so the swap is instant with no reconnect) — like tapping
    /// the PiP on macOS.
    /// </summary>
    public void SwapPlaybackWith(CameraTileViewModel other)
    {
        if (Client is not { } mine || other.Client is not { } theirs) return;
        UnsubscribeClient(mine);
        other.UnsubscribeClient(theirs);
        (_handle, other._handle) = (other._handle, _handle);
        (_fixedQuality, other._fixedQuality) = (other._fixedQuality, _fixedQuality);
        (Client, other.Client) = (theirs, mine);
        SubscribeClient(theirs);
        other.SubscribeClient(mine);
        // Audio follows the focused tile onto its new client.
        ApplyAudioRouting();
        other.ApplyAudioRouting();
    }

    /// <summary>Release this tile's claim on the stream (the shared client stops
    /// and frees its allocation only when no other view is using it).</summary>
    public void Stop()
    {
        if (Client is { } c)
        {
            // Release audio, but only if this tile routed it: the shared client
            // may keep running for other views (e.g. the grid tile after focus
            // exits), and a stopping grid tile must not silence a focused one.
            if (IsFocused || _pinned) c.SetAudioActive(false);
            UnsubscribeClient(c);
        }
        _handle?.Dispose();
        _handle = null;
        IsPlaying = false;
        IsLoading = false;
    }

    public void Dispose() => Stop();
}
