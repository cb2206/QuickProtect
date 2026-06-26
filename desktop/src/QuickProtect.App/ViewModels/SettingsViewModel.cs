using Avalonia.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.App.Platform;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// Settings window: controller connection (IP, API key), optional classic-API
/// credentials for PTZ, default stream quality, launch-at-login, and the
/// trust-on-first-use certificate state. Writes straight through to
/// <see cref="AppSettings"/> (which persists to prefs/secret store).
/// </summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;
    private readonly CertificateTrust _trust;
    private readonly UpdateChecker _updater;

    [ObservableProperty] private string _ipAddress;
    [ObservableProperty] private string _apiKey;
    [ObservableProperty] private string _username;
    [ObservableProperty] private string _password;
    [ObservableProperty] private bool _launchAtLogin;
    [ObservableProperty] private int _defaultQualityIndex;
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private bool _hasPendingCert;
    [ObservableProperty] private string _hotkeyDisplay = "Not set";
    [ObservableProperty] private bool _isRecordingHotkey;
    [ObservableProperty] private bool _updateAvailable;
    [ObservableProperty] private string _updateVersion = "";

    public string[] QualityOptions { get; } =
    {
        Localization.Loc.Get("Auto"), Localization.Loc.Get("High"),
        Localization.Loc.Get("Medium"), Localization.Loc.Get("Low")
    };

    // Language picker: index 0 = system default, then one per supported culture.
    public string[] LanguageNames { get; } =
        { "System default", "English", "Deutsch", "Français", "Español", "Nederlands", "Italiano", "Português (BR)" };
    private static readonly string?[] LanguageCodes = { null, "en", "de", "fr", "es", "nl", "it", "pt-BR" };

    [ObservableProperty] private int _languageIndex;

    partial void OnLanguageIndexChanged(int value)
    {
        if (value < 0 || value >= LanguageCodes.Length) return;
        _settings.LanguageOverride = LanguageCodes[value];
        StatusMessage = "Restart QuickProtect to apply the language change.";
    }

    /// <summary>The "Cameras &amp; Layout" tab's view model.</summary>
    public LayoutViewModel Layout { get; }

    public SettingsViewModel(ProtectService service, AppSettings settings, CertificateTrust trust, UpdateChecker updater)
    {
        _service = service;
        _settings = settings;
        _trust = trust;
        _updater = updater;
        Layout = new LayoutViewModel(service, settings);
        _updateAvailable = updater.UpdateAvailable;
        _updateVersion = updater.LatestVersion;
        updater.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(UpdateChecker.UpdateAvailable) or nameof(UpdateChecker.LatestVersion))
                Avalonia.Threading.Dispatcher.UIThread.Post(() =>
                {
                    UpdateAvailable = updater.UpdateAvailable;
                    UpdateVersion = updater.LatestVersion;
                });
        };

        _ipAddress = settings.IpAddress;
        _apiKey = settings.ApiKey;
        _username = settings.Username;
        _password = settings.Password;
        _launchAtLogin = settings.LaunchAtLogin;
        _defaultQualityIndex = (int)settings.DefaultStreamQuality;
        _languageIndex = Math.Max(0, Array.IndexOf(LanguageCodes, settings.LanguageOverride));
        RefreshCertState();
        RefreshHotkey();
    }

    // MARK: - Global hotkey capture

    private void RefreshHotkey()
    {
        var hk = _settings.GlobalHotkey();
        HotkeyDisplay = HotkeyCodec.Display(hk?.keyCode, hk?.modifiers);
    }

    [RelayCommand]
    private void RecordHotkey()
    {
        IsRecordingHotkey = true;
        HotkeyDisplay = "Press a key combination…";
    }

    [RelayCommand]
    private void ClearHotkey()
    {
        _settings.ClearGlobalHotkey();
        IsRecordingHotkey = false;
        RefreshHotkey();
    }

    /// <summary>Called by the window while recording; stores the captured combo.</summary>
    public void CaptureHotkey(Key key, KeyModifiers modifiers)
    {
        if (!IsRecordingHotkey) return;
        if (HotkeyCodec.IsModifierKey(key)) return; // wait for a non-modifier key
        if (key == Key.Escape) { IsRecordingHotkey = false; RefreshHotkey(); return; }
        if (HotkeyCodec.VirtualKey(key) is not { } vk)
        {
            StatusMessage = "Unsupported key — use a letter, number, or function key.";
            return;
        }
        _settings.SetGlobalHotkey(vk, HotkeyCodec.Modifiers(modifiers));
        IsRecordingHotkey = false;
        RefreshHotkey();
    }

    partial void OnDefaultQualityIndexChanged(int value)
        => _settings.DefaultStreamQuality = (StreamQuality)Math.Clamp(value, 0, 3);

    partial void OnLaunchAtLoginChanged(bool value) => _settings.LaunchAtLogin = value;

    private void RefreshCertState()
        => HasPendingCert = !string.IsNullOrEmpty(_settings.IpAddress)
                            && _trust.Pending(_settings.IpAddress) != null;

    [RelayCommand]
    private async Task Save()
    {
        _settings.IpAddress = IpAddress.Trim();
        _settings.ApiKey = ApiKey.Trim();
        _settings.Username = Username.Trim();
        _settings.Password = Password;
        StatusMessage = "Saved. Testing connection…";
        await TestConnection();
    }

    [RelayCommand]
    private async Task TestConnection()
    {
        _settings.IpAddress = IpAddress.Trim();
        _settings.ApiKey = ApiKey.Trim();
        await _service.FetchCamerasAsync();
        RefreshCertState();
        StatusMessage = _service.ErrorMessage is { } err
            ? $"Error: {err}"
            : $"Connected — {_service.Cameras.Count} camera(s) found.";
    }

    [RelayCommand]
    private async Task CheckForUpdates()
    {
        StatusMessage = "Checking for updates…";
        await _updater.CheckForUpdateAsync();
        StatusMessage = _updater.UpdateAvailable
            ? $"Update available: {_updater.LatestVersion}"
            : "You're on the latest version.";
    }

    [RelayCommand]
    private void OpenReleasePage()
        => UrlOpener.Open(_updater.ReleaseUrl ?? _updater.ReleasesPageUrl);

    [RelayCommand]
    private void TrustNewCertificate()
    {
        if (string.IsNullOrEmpty(_settings.IpAddress)) return;
        _trust.TrustPending(_settings.IpAddress);
        RefreshCertState();
        StatusMessage = "New certificate trusted.";
    }
}
