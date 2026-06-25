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
    public MediaPlayer Player { get; }

    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isOnline;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private bool _isFocused;
    [ObservableProperty] private bool _isMuted;
    [ObservableProperty] private bool _fillMode;

    private string? _activeQuality;
    private bool _starting;
    private readonly bool _pinned;

    /// <param name="pinned">
    /// When true the tile drives a pinned floating window: it uses the pinned
    /// server-side allocation lifecycle (created/released independently of the
    /// popover's streams) and always streams at high quality.
    /// </param>
    public CameraTileViewModel(Camera camera, ProtectService service, AppSettings settings, bool pinned = false)
    {
        _service = service;
        _settings = settings;
        _pinned = pinned;
        Camera = camera;
        _name = camera.Name;
        _isOnline = camera.IsOnline;
        _isMuted = !settings.SpeakerEnabled;
        _fillMode = settings.CameraFillMode(camera.Id) ?? false;
        Player = new MediaPlayer(VlcManager.Shared.LibVLC) { EnableHardwareDecoding = true };
        Player.Playing += (_, _) =>
        {
            IsPlaying = true;
            IsLoading = false;
            ApplyMute();
            ApplyFill();
        };
        Player.EncounteredError += (_, _) => IsLoading = false;
        Player.Stopped += (_, _) => IsPlaying = false;
    }

    // MARK: - Audio mute / fit-fill (applied to the player; persisted to settings)

    /// <summary>Toggle audio. Persists the global speaker preference (default muted).</summary>
    public void ToggleMute()
    {
        IsMuted = !IsMuted;
        _settings.SpeakerEnabled = !IsMuted;
        ApplyMute();
    }

    private void ApplyMute() => Player.Mute = IsMuted;

    /// <summary>Toggle fit (letterbox) vs. fill (crop) for the focused frame.</summary>
    public void ToggleFill()
    {
        FillMode = !FillMode;
        _settings.SetCameraFillMode(FillMode, Camera.Id);
        ApplyFill();
    }

    private void ApplyFill()
    {
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
        if (_starting || Player.IsPlaying || !Camera.IsOnline) return;
        _starting = true;
        IsLoading = true;
        try
        {
            var gridIsLarge = _settings.SizeFor(Camera.Id) == AppSettings.CameraSize.Large;
            // Pinned and focused views both run at high quality.
            var quality = _settings.EffectiveStreamQuality(Camera.Id)
                .Resolve(focused: IsFocused || _pinned, gridIsLarge: gridIsLarge)
                .ApiValue();

            var result = _pinned
                ? await _service.CreatePinnedStreamUrlAsync(Camera, quality)
                : await _service.CreateRtspStreamUrlAsync(Camera, quality);
            if (result is not { } r) { IsLoading = false; return; }
            _activeQuality = r.quality;

            using var media = VlcManager.Shared.MakeMedia(r.url);
            Player.Play(media);
        }
        catch (Exception ex)
        {
            Log.Line($"[Tile] start failed for {Camera.Name}: {ex.Message}");
            IsLoading = false;
        }
        finally { _starting = false; }
    }

    public void Stop()
    {
        if (Player.IsPlaying) Player.Stop();
        if (_activeQuality is { } q)
        {
            if (_pinned) _service.ReleasePinnedStream(Camera.Id, q);
            else _service.ReleaseStream(Camera.Id, q);
            _activeQuality = null;
        }
        IsPlaying = false;
        IsLoading = false;
    }

    public void Dispose()
    {
        Stop();
        Player.Dispose();
    }
}
