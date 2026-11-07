using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// First-run onboarding: Connect → PTZ (optional) → All set. Mirrors the macOS
/// 3-step <c>OnboardingView</c>. Writes connection details into <see cref="AppSettings"/>
/// and marks onboarding complete on finish.
/// </summary>
public sealed partial class OnboardingViewModel : ObservableObject
{
    private readonly ProtectHub _service;
    private readonly AppSettings _settings;
    /// <summary>The site onboarding configures — the first one.</summary>
    private readonly ControllerSite _site;

    /// <summary>Raised when the wizard is finished or skipped (host closes the window).</summary>
    public event EventHandler? Finished;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsStep1))]
    [NotifyPropertyChangedFor(nameof(IsStep2))]
    [NotifyPropertyChangedFor(nameof(IsStep3))]
    [NotifyPropertyChangedFor(nameof(ContinueLabel))]
    [NotifyPropertyChangedFor(nameof(CanGoBack))]
    private int _step = 1;

    [ObservableProperty] private string _ipAddress = "";
    [ObservableProperty] private string _apiKey = "";
    [ObservableProperty] private string _username = "";
    [ObservableProperty] private string _password = "";
    [ObservableProperty] private bool _launchAtLogin;
    [ObservableProperty] private string _statusMessage = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CameraCountLabel))]
    private int _cameraCount;

    /// <summary>Localized "N cameras detected." line (reuses the macOS catalog key).</summary>
    public string CameraCountLabel
        => Localization.Loc.Get("%lld cameras detected.").Replace("%lld", CameraCount.ToString());

    /// <summary>Where on the console to create the API key / PTZ account (the "?" flyouts).</summary>
    public string ApiKeyHelp => Localization.Loc.Get("Create the key on this console, not at unifi.ui.com: open UniFi Network → Integrations → Create New API Key (on Network 9: Settings → Control Plane → Integrations). Each console needs its own key.");
    public string PtzAccountHelp => Localization.Loc.Get("Use a local account on this console: in UniFi OS open Admins & Users → Create New, tick “Restrict to Local Access Only”, and give it a Protect role that can control cameras.");

    public bool IsStep1 => Step == 1;
    public bool IsStep2 => Step == 2;
    public bool IsStep3 => Step == 3;
    public bool CanGoBack => Step > 1;
    public string ContinueLabel => Localization.Loc.Get(Step < 3 ? "Continue" : "Finish");

    public OnboardingViewModel(ProtectHub service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        _site = settings.Sites[0];
        _ipAddress = _site.IpAddress;
        _apiKey = _site.ApiKey;
        _username = _site.Username;
        _password = _site.Password;
        _launchAtLogin = settings.LaunchAtLogin;
    }

    [RelayCommand]
    private void Continue()
    {
        if (Step < 3) { PersistConnection(); Step++; }
        else Finish();
    }

    [RelayCommand]
    private void Back() { if (Step > 1) Step--; }

    [RelayCommand]
    private void Skip() => Finish();

    [RelayCommand]
    private async Task TestConnection()
    {
        PersistConnection();
        StatusMessage = Localization.Loc.Get("Testing…");
        var siteService = _service.ServiceForSite(_site.Id);
        if (siteService != null) await siteService.FetchCamerasAsync(forced: true);
        _service.Recompute();
        CameraCount = siteService?.Cameras.Count ?? 0;
        StatusMessage = siteService?.ErrorMessage is { } err
            ? string.Format(Localization.Loc.Get("Error: {0}"), Localization.Loc.Get(err))
            : Localization.Loc.Get("Connected — %lld cameras found")
                .Replace("%lld", CameraCount.ToString());
    }

    private void PersistConnection()
    {
        _site.IpAddress = IpAddress.Trim();
        _site.ApiKey = ApiKey.Trim();
        _site.Username = Username.Trim();
        _site.Password = Password;
    }

    private void Finish()
    {
        PersistConnection();
        _settings.LaunchAtLogin = LaunchAtLogin;
        _settings.HasCompletedOnboarding = true;
        _settings.HasShownAutoStartPrompt = true; // the wizard replaces the legacy prompt
        Finished?.Invoke(this, EventArgs.Empty);
    }
}
