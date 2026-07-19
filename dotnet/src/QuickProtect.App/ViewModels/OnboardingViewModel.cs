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
    private readonly ProtectService _service;
    private readonly AppSettings _settings;

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

    public bool IsStep1 => Step == 1;
    public bool IsStep2 => Step == 2;
    public bool IsStep3 => Step == 3;
    public bool CanGoBack => Step > 1;
    public string ContinueLabel => Localization.Loc.Get(Step < 3 ? "Continue" : "Finish");

    public OnboardingViewModel(ProtectService service, AppSettings settings)
    {
        _service = service;
        _settings = settings;
        _ipAddress = settings.IpAddress;
        _apiKey = settings.ApiKey;
        _username = settings.Username;
        _password = settings.Password;
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
        await _service.FetchCamerasAsync();
        CameraCount = _service.Cameras.Count;
        StatusMessage = _service.ErrorMessage is { } err
            ? string.Format(Localization.Loc.Get("Error: {0}"), err)
            : Localization.Loc.Get("Connected — %lld cameras found")
                .Replace("%lld", CameraCount.ToString());
    }

    private void PersistConnection()
    {
        _settings.IpAddress = IpAddress.Trim();
        _settings.ApiKey = ApiKey.Trim();
        _settings.Username = Username.Trim();
        _settings.Password = Password;
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
