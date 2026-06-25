using System.Collections.ObjectModel;
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Avalonia.Threading;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// Backs the camera-grid panel: keeps the tile collection in sync with
/// <see cref="ProtectService.Cameras"/>, honoring the active layout profile's
/// visibility and ordering. Equivalent to the macOS PopoverContentView/CameraGridView state.
/// </summary>
public sealed partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;

    public ObservableCollection<CameraTileViewModel> Tiles { get; } = new();

    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private bool _hasCameras;

    public MainViewModel(ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        _service.PropertyChanged += OnServiceChanged;
        RebuildTiles();
    }

    private void OnServiceChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.UIThread.Post(() =>
        {
            switch (e.PropertyName)
            {
                case nameof(ProtectService.Cameras): RebuildTiles(); break;
                case nameof(ProtectService.IsLoading): IsLoading = _service.IsLoading; break;
                case nameof(ProtectService.ErrorMessage): ErrorMessage = _service.ErrorMessage; break;
            }
        });
    }

    private void RebuildTiles()
    {
        var visible = _settings.OrderedCameras(_settings.VisibleCameras(_service.Cameras));
        var byId = Tiles.ToDictionary(t => t.Camera.Id);

        // Stop+drop tiles whose camera disappeared.
        foreach (var tile in Tiles.ToList())
            if (!visible.Any(c => c.Id == tile.Camera.Id))
            {
                tile.Dispose();
                Tiles.Remove(tile);
            }

        // Add/refresh in profile order.
        for (var i = 0; i < visible.Count; i++)
        {
            var cam = visible[i];
            if (byId.TryGetValue(cam.Id, out var existing))
            {
                existing.UpdateFrom(cam);
                var currentIndex = Tiles.IndexOf(existing);
                if (currentIndex != i && i < Tiles.Count) Tiles.Move(currentIndex, i);
            }
            else
            {
                var tile = new CameraTileViewModel(cam, _service, _settings);
                Tiles.Insert(Math.Min(i, Tiles.Count), tile);
                _ = tile.StartAsync();
            }
        }
        HasCameras = Tiles.Count > 0;
    }

    [RelayCommand]
    private async Task Refresh() => await _service.FetchCamerasAsync();

    /// <summary>Stop all tiles and release their server-side allocations (panel hidden).</summary>
    public void StopAll()
    {
        foreach (var tile in Tiles) tile.Stop();
        _service.CleanupStreams();
    }

    public void StartAll()
    {
        foreach (var tile in Tiles) _ = tile.StartAsync();
    }

    public void Dispose()
    {
        _service.PropertyChanged -= OnServiceChanged;
        foreach (var tile in Tiles) tile.Dispose();
        Tiles.Clear();
    }
}
