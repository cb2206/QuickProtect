using System.Collections.ObjectModel;
using System.ComponentModel;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// "Cameras &amp; Layout" settings: layout-profile switcher (create/rename/delete)
/// and per-camera visibility, size, and ordering within the active profile.
/// Writes straight through to <see cref="AppSettings"/>.
/// </summary>
public sealed partial class LayoutViewModel : ObservableObject
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;
    private bool _suppressProfileSwitch;

    public ObservableCollection<CameraRowViewModel> Rows { get; } = new();
    public ObservableCollection<string> ProfileNames { get; } = new();

    [ObservableProperty] private int _selectedProfileIndex;
    [ObservableProperty] private string _newProfileName = "";

    public LayoutViewModel(ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        _service.PropertyChanged += OnServiceChanged;
        _settings.LayoutProfileChanged += (_, _) => Dispatcher.UIThread.Post(RebuildRows);
        _settings.PropertyChanged += OnSettingsChanged;
        RebuildProfiles();
        RebuildRows();
    }

    private void OnServiceChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ProtectService.Cameras))
            Dispatcher.UIThread.Post(RebuildRows);
    }

    /// <summary>
    /// Profile list or active profile changed — here or from the main window's
    /// view menu, which edits the same <see cref="AppSettings"/> — so the
    /// switcher follows along.
    /// </summary>
    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppSettings.Profiles) or nameof(AppSettings.ActiveProfileId))
            Dispatcher.UIThread.Post(RebuildProfiles);
    }

    private IReadOnlyList<AppSettings.LayoutProfile> _profiles = Array.Empty<AppSettings.LayoutProfile>();

    private void RebuildProfiles()
    {
        _profiles = _settings.Profiles();
        _suppressProfileSwitch = true;
        ProfileNames.Clear();
        foreach (var p in _profiles) ProfileNames.Add(p.Name);
        var idx = _profiles.ToList().FindIndex(p => p.Id == _settings.ActiveProfileId);
        SelectedProfileIndex = idx < 0 ? 0 : idx;
        _suppressProfileSwitch = false;
    }

    private void RebuildRows()
    {
        Rows.Clear();
        // All cameras (incl. hidden) in profile order, so the user can re-show them.
        foreach (var cam in _settings.OrderedCameras(_service.Cameras))
            Rows.Add(new CameraRowViewModel(cam, _settings, this));
    }

    partial void OnSelectedProfileIndexChanged(int value)
    {
        if (_suppressProfileSwitch) return;
        if (value < 0 || value >= _profiles.Count) return;
        _settings.SwitchProfile(_profiles[value].Id);
        RebuildRows();
    }

    /// <summary>Reorder a row by <paramref name="delta"/> (−1 up, +1 down) and persist.</summary>
    public void Move(CameraRowViewModel row, int delta)
    {
        var i = Rows.IndexOf(row);
        var j = i + delta;
        if (i < 0 || j < 0 || j >= Rows.Count) return;
        Rows.Move(i, j);
        _settings.SetCameraOrder(Rows.Select(r => r.Camera.Id).ToList());
    }

    [RelayCommand]
    private void CreateProfile()
    {
        var name = NewProfileName.Trim();
        if (name.Length == 0) return;
        _settings.CreateProfile(name);
        NewProfileName = "";
    }

    [RelayCommand]
    private void RenameProfile()
    {
        var name = NewProfileName.Trim();
        if (name.Length == 0 || SelectedProfileIndex < 0 || SelectedProfileIndex >= _profiles.Count) return;
        _settings.RenameProfile(_profiles[SelectedProfileIndex].Id, name);
        NewProfileName = "";
    }

    [RelayCommand]
    private void DeleteProfile()
    {
        if (SelectedProfileIndex < 0 || SelectedProfileIndex >= _profiles.Count) return;
        _settings.DeleteProfile(_profiles[SelectedProfileIndex].Id);
    }
}
