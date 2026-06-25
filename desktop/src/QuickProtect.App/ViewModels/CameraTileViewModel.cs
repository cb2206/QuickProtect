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

    private string? _activeQuality;
    private bool _starting;

    public CameraTileViewModel(Camera camera, ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        Camera = camera;
        _name = camera.Name;
        _isOnline = camera.IsOnline;
        Player = new MediaPlayer(VlcManager.Shared.LibVLC) { EnableHardwareDecoding = true };
        Player.Playing += (_, _) => { IsPlaying = true; IsLoading = false; };
        Player.EncounteredError += (_, _) => IsLoading = false;
        Player.Stopped += (_, _) => IsPlaying = false;
    }

    public void UpdateFrom(Camera camera)
    {
        Camera = camera;
        Name = camera.Name;
        IsOnline = camera.IsOnline;
    }

    /// <summary>Resolve the effective quality for the current view state and start playback.</summary>
    public async Task StartAsync()
    {
        if (_starting || Player.IsPlaying || !Camera.IsOnline) return;
        _starting = true;
        IsLoading = true;
        try
        {
            var gridIsLarge = _settings.SizeFor(Camera.Id) == AppSettings.CameraSize.Large;
            var quality = _settings.EffectiveStreamQuality(Camera.Id)
                .Resolve(focused: IsFocused, gridIsLarge: gridIsLarge)
                .ApiValue();

            var result = await _service.CreateRtspStreamUrlAsync(Camera, quality);
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
            _service.ReleaseStream(Camera.Id, q);
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
