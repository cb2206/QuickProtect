using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// One row in the Cameras &amp; Layout settings list: visibility, tile size, and
/// reordering for a single camera within the active layout profile.
/// </summary>
public sealed partial class CameraRowViewModel : ObservableObject
{
    private readonly AppSettings _settings;
    private readonly LayoutViewModel _parent;

    public Camera Camera { get; }
    public string Name => Camera.Name;

    [ObservableProperty] private bool _isVisible;
    [ObservableProperty] private int _sizeIndex; // 0 small, 1 medium, 2 large

    // Secondary-lens (package camera) PiP toggles; sub-rows shown only for
    // cameras with a second lens (macOS secondaryLensRow parity).
    public bool HasSecondaryLens => Camera.Secondary != null;
    public string SecondaryLensLabel => Localization.Loc.Get("Package camera");
    [ObservableProperty] private bool _showsPip;
    [ObservableProperty] private bool _showsGridPip;

    public string[] SizeOptions { get; } =
        { Localization.Loc.Get("Small"), Localization.Loc.Get("Medium"), Localization.Loc.Get("Large") };

    public CameraRowViewModel(Camera camera, AppSettings settings, LayoutViewModel parent)
    {
        Camera = camera;
        _settings = settings;
        _parent = parent;
        _isVisible = !settings.IsHidden(camera.Id);
        _sizeIndex = settings.SizeFor(camera.Id) switch
        {
            AppSettings.CameraSize.Small => 0,
            AppSettings.CameraSize.Large => 2,
            _ => 1
        };
        _showsPip = settings.ShowsSecondaryLensPip(camera.Id);
        _showsGridPip = settings.ShowsSecondaryLensPipInGrid(camera.Id);
    }

    partial void OnIsVisibleChanged(bool value) => _settings.SetHidden(!value, Camera.Id);

    partial void OnShowsPipChanged(bool value) => _settings.SetShowsSecondaryLensPip(value, Camera.Id);

    partial void OnShowsGridPipChanged(bool value) => _settings.SetShowsSecondaryLensPipInGrid(value, Camera.Id);

    partial void OnSizeIndexChanged(int value) => _settings.SetSize(value switch
    {
        0 => AppSettings.CameraSize.Small,
        2 => AppSettings.CameraSize.Large,
        _ => AppSettings.CameraSize.Medium
    }, Camera.Id);

    [RelayCommand] private void MoveUp() => _parent.Move(this, -1);
    [RelayCommand] private void MoveDown() => _parent.Move(this, 1);
}
