using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
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

    [ObservableProperty] private string _ipAddress;
    [ObservableProperty] private string _apiKey;
    [ObservableProperty] private string _username;
    [ObservableProperty] private string _password;
    [ObservableProperty] private bool _launchAtLogin;
    [ObservableProperty] private int _defaultQualityIndex;
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private bool _hasPendingCert;

    public string[] QualityOptions { get; } = { "Auto", "High", "Medium", "Low" };

    /// <summary>The "Cameras &amp; Layout" tab's view model.</summary>
    public LayoutViewModel Layout { get; }

    public SettingsViewModel(ProtectService service, AppSettings settings, CertificateTrust trust)
    {
        _service = service;
        _settings = settings;
        _trust = trust;
        Layout = new LayoutViewModel(service, settings);

        _ipAddress = settings.IpAddress;
        _apiKey = settings.ApiKey;
        _username = settings.Username;
        _password = settings.Password;
        _launchAtLogin = settings.LaunchAtLogin;
        _defaultQualityIndex = (int)settings.DefaultStreamQuality;
        RefreshCertState();
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
    private void TrustNewCertificate()
    {
        if (string.IsNullOrEmpty(_settings.IpAddress)) return;
        _trust.TrustPending(_settings.IpAddress);
        RefreshCertState();
        StatusMessage = "New certificate trusted.";
    }
}
