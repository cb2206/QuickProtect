using System.Collections.ObjectModel;
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Avalonia.Threading;
using QuickProtect.Core.Models;
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

    /// <summary>
    /// The camera shown enlarged in focus mode, or null for the grid. Focus uses
    /// a dedicated tile (its own high-quality stream + player) so it never shares
    /// a <c>MediaPlayer</c> with a grid tile.
    /// </summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsFocusMode))]
    [NotifyPropertyChangedFor(nameof(IsGridMode))]
    private CameraTileViewModel? _focusTile;

    public bool IsFocusMode => FocusTile != null;
    public bool IsGridMode => FocusTile == null;

    /// <summary>Transient status line (e.g. "Saved snapshot"), auto-clears.</summary>
    [ObservableProperty] private string? _statusToast;
    private int _toastToken;

    public async void ShowToast(string message)
    {
        StatusToast = message;
        var token = ++_toastToken;
        await Task.Delay(2500);
        if (token == _toastToken) StatusToast = null;
    }

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

    /// <summary>
    /// Enter focus mode for <paramref name="camera"/>: stop the grid streams to
    /// free resources, then start a dedicated high-quality stream for the focused
    /// camera. Mirrors the macOS grid→focus transition.
    /// </summary>
    public void Focus(Camera camera)
    {
        if (IsFocusMode) return;
        foreach (var tile in Tiles) tile.Stop();
        _service.CleanupStreams();

        var ft = new CameraTileViewModel(camera, _service, _settings);
        ft.SetFocused(true);
        FocusTile = ft;
        _ = ft.StartAsync();
    }

    /// <summary>Leave focus mode, stop PTZ motion, and restart the grid.</summary>
    public void ExitFocus()
    {
        if (FocusTile is not { } ft) return;
        ft.PtzStopAll();
        ft.Dispose();
        FocusTile = null;
        StartAll();
    }

    /// <summary>Stop all tiles and release their server-side allocations (panel hidden).</summary>
    public void StopAll()
    {
        FocusTile?.PtzStopAll();
        FocusTile?.Stop();
        foreach (var tile in Tiles) tile.Stop();
        _service.CleanupStreams();
    }

    public void StartAll()
    {
        if (IsFocusMode) { _ = FocusTile!.StartAsync(); return; }
        foreach (var tile in Tiles) _ = tile.StartAsync();
    }

    public void Dispose()
    {
        _service.PropertyChanged -= OnServiceChanged;
        FocusTile?.Dispose();
        foreach (var tile in Tiles) tile.Dispose();
        Tiles.Clear();
    }
}
