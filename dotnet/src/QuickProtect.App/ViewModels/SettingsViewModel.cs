using System.Reflection;
using Avalonia.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.App.Platform;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>
/// Settings window: sidebar-sectioned (General / Connection / PTZ / Cameras /
/// Shortcuts / Updates) mirroring the macOS SettingsView. Every control writes
/// straight through to <see cref="AppSettings"/> (which persists to prefs/secret
/// store) — there is no explicit Save.
/// </summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ProtectService _service;
    private readonly AppSettings _settings;
    private readonly CertificateTrust _trust;
    private readonly UpdateChecker _updater;

    // Sidebar sections, in display order.
    private const int SectionGeneral = 0;
    private const int SectionConnection = 1;
    private const int SectionPtz = 2;
    private const int SectionCameras = 3;
    private const int SectionShortcuts = 4;
    private const int SectionUpdates = 5;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsGeneralSection))]
    [NotifyPropertyChangedFor(nameof(IsConnectionSection))]
    [NotifyPropertyChangedFor(nameof(IsPtzSection))]
    [NotifyPropertyChangedFor(nameof(IsCamerasSection))]
    [NotifyPropertyChangedFor(nameof(IsShortcutsSection))]
    [NotifyPropertyChangedFor(nameof(IsUpdatesSection))]
    [NotifyPropertyChangedFor(nameof(SectionTitle))]
    private int _selectedSectionIndex;

    public bool IsGeneralSection => SelectedSectionIndex == SectionGeneral;
    public bool IsConnectionSection => SelectedSectionIndex == SectionConnection;
    public bool IsPtzSection => SelectedSectionIndex == SectionPtz;
    public bool IsCamerasSection => SelectedSectionIndex == SectionCameras;
    public bool IsShortcutsSection => SelectedSectionIndex == SectionShortcuts;
    public bool IsUpdatesSection => SelectedSectionIndex == SectionUpdates;

    public string SectionTitle => SelectedSectionIndex switch
    {
        SectionConnection => Localization.Loc.Get("Connection"),
        SectionPtz => Localization.Loc.Get("PTZ"),
        SectionCameras => Localization.Loc.Get("Cameras"),
        SectionShortcuts => Localization.Loc.Get("Shortcuts"),
        SectionUpdates => Localization.Loc.Get("Updates"),
        _ => Localization.Loc.Get("General"),
    };

    // Header status pill: Integration-API state everywhere except the PTZ
    // section, where it reflects the classic-API login (macOS parity).
    [ObservableProperty] private bool _badgeConnected;
    [ObservableProperty] private string _badgeText = "";

    [ObservableProperty] private string _ipAddress;
    [ObservableProperty] private string _apiKey;
    [ObservableProperty] private string _username;
    [ObservableProperty] private string _password;
    [ObservableProperty] private bool _launchAtLogin;
    [ObservableProperty] private int _defaultQualityIndex;
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private string _ptzStatusMessage = "";
    [ObservableProperty] private string _updateStatusMessage = "";
    [ObservableProperty] private bool _showLanguageRestartHint;
    [ObservableProperty] private bool _hasPendingCert;
    [ObservableProperty] private string _hotkeyDisplay = Localization.Loc.Get("Not set");
    [ObservableProperty] private bool _isRecordingHotkey;
    [ObservableProperty] private bool _updateAvailable;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(UpdateBannerText))]
    private string _updateVersion = "";

    /// <summary>Localized "A new version (x.y.z) is available." banner text.</summary>
    public string UpdateBannerText
        => string.Format(Localization.Loc.Get("A new version ({0}) is available."), UpdateVersion);
    [ObservableProperty] private bool _showFocusOverlayControls;
    [ObservableProperty] private int _accentIndex;
    [ObservableProperty] private int _appearanceIndex; // 0 auto, 1 light, 2 dark

    public string[] AppearanceOptions { get; } =
        { Localization.Loc.Get("Auto"), Localization.Loc.Get("Light"), Localization.Loc.Get("Dark") };

    public string[] AccentNames { get; } =
    {
        Localization.Loc.Get("Blue"), Localization.Loc.Get("Purple"), Localization.Loc.Get("Pink"),
        Localization.Loc.Get("Orange"), Localization.Loc.Get("Green"), Localization.Loc.Get("Red"),
        Localization.Loc.Get("Teal")
    };
    private static readonly string[] AccentHexes = { "0a84ff", "bf5af2", "ff375f", "ff9f0a", "30d158", "ff453a", "40c8e0" };
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SnapshotFolderRowVisible))]
    private int _snapshotDestinationIndex; // 0 clipboard, 1 folder

    public bool SnapshotFolderRowVisible => SnapshotDestinationIndex == 1;

    [ObservableProperty] private string _snapshotFolderDisplay = "";

    public string[] SnapshotDestinations { get; } =
        { Localization.Loc.Get("Clipboard"), Localization.Loc.Get("Folder") };

    /// <summary>Set by the window so the folder picker can use its StorageProvider.</summary>
    public Func<Task<string?>>? PickFolderAsync { get; set; }

    public string[] QualityOptions { get; } =
    {
        Localization.Loc.Get("Auto"), Localization.Loc.Get("High"),
        Localization.Loc.Get("Medium"), Localization.Loc.Get("Low")
    };

    // Stream keep-alive grace on panel close (macOS: Settings → Connection).
    public string[] KeepAliveOptions { get; } =
        { Localization.Loc.Get("Off"), "5 s", "10 s", "30 s", "60 s" };
    private static readonly int[] KeepAliveValues = { 0, 5, 10, 30, 60 };

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PauseDecodeRowVisible))]
    private int _keepAliveIndex;

    /// <summary>The pause-decode switch only applies while a grace is configured.</summary>
    public bool PauseDecodeRowVisible => KeepAliveIndex > 0;

    [ObservableProperty] private bool _pauseDecodeWhileClosed;

    partial void OnKeepAliveIndexChanged(int value)
    {
        if (value < 0 || value >= KeepAliveValues.Length) return;
        _settings.StreamKeepAliveSeconds = KeepAliveValues[value];
    }

    partial void OnPauseDecodeWhileClosedChanged(bool value)
        => _settings.PauseDecodeWhileClosed = value;

    // Language picker: index 0 = system default, then one per supported culture.
    // The language names themselves are endonyms and stay untranslated.
    public string[] LanguageNames { get; } =
        { Localization.Loc.Get("System default"), "English", "Deutsch", "Français", "Español", "Nederlands", "Italiano", "Português (BR)" };
    private static readonly string?[] LanguageCodes = { null, "en", "de", "fr", "es", "nl", "it", "pt-BR" };

    [ObservableProperty] private int _languageIndex;

    partial void OnLanguageIndexChanged(int value)
    {
        if (value < 0 || value >= LanguageCodes.Length) return;
        _settings.LanguageOverride = LanguageCodes[value];
        ShowLanguageRestartHint = true;
    }

    /// <summary>Installed app version for the Updates section, e.g. "v1.4.0".</summary>
    public string AppVersion { get; } = "v" +
        (Assembly.GetEntryAssembly()
             ?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
             ?.InformationalVersion.Split('+')[0]
         ?? Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3)
         ?? "?");

    /// <summary>
    /// Hides the update-check row in store/packaged builds (Microsoft Store,
    /// Flatpak, Snap) — there, updates arrive through the store or package
    /// manager, mirroring the hidden Updates tab in macOS App Store builds.
    /// </summary>
    public bool IsUpdateCheckAvailable { get; } = !AppDistribution.IsExternallyManaged;

    /// <summary>
    /// False in an MSIX package, where Windows owns the startup switch. The
    /// toggle is replaced by a pointer to the OS setting rather than shown as
    /// a control that cannot take effect.
    /// </summary>
    public bool IsLaunchAtLoginConfigurable { get; private set; } = true;

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
        IsLaunchAtLoginConfigurable = !settings.LaunchManager.IsManagedByOS;
        _defaultQualityIndex = (int)settings.DefaultStreamQuality;
        _languageIndex = Math.Max(0, Array.IndexOf(LanguageCodes, settings.LanguageOverride));
        _showFocusOverlayControls = settings.ShowFocusOverlayControls;
        _accentIndex = Math.Max(0, Array.IndexOf(AccentHexes, settings.AccentColorHex));
        _appearanceIndex = (int)settings.Appearance;
        _snapshotDestinationIndex = (int)settings.SnapshotDest;
        _snapshotFolderDisplay = settings.SnapshotFolder ?? "";
        var keepAliveIdx = Array.IndexOf(KeepAliveValues, settings.StreamKeepAliveSeconds);
        _keepAliveIndex = keepAliveIdx >= 0 ? keepAliveIdx
            : Array.IndexOf(KeepAliveValues, AppSettings.StreamKeepAliveDefault);
        _pauseDecodeWhileClosed = settings.PauseDecodeWhileClosed;
        RefreshCertState();
        RefreshHotkey();
        RefreshBadge();

        service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ProtectService.ErrorMessage)
                or nameof(ProtectService.Cameras)
                or nameof(ProtectService.IsClassicLoggedIn))
                Avalonia.Threading.Dispatcher.UIThread.Post(RefreshBadge);
        };
    }

    partial void OnSelectedSectionIndexChanged(int value) => RefreshBadge();

    private void RefreshBadge()
    {
        if (SelectedSectionIndex == SectionPtz)
        {
            var configured = !string.IsNullOrEmpty(Username) && !string.IsNullOrEmpty(Password);
            BadgeConnected = _service.IsClassicLoggedIn;
            BadgeText = _service.IsClassicLoggedIn
                ? Localization.Loc.Get("Connected")
                : configured ? Localization.Loc.Get("Not verified") : Localization.Loc.Get("Not configured");
        }
        else
        {
            BadgeConnected = _service.ErrorMessage == null && _service.Cameras.Count > 0;
            BadgeText = _service.ErrorMessage == null
                ? Localization.Loc.Get("Connected")
                : Localization.Loc.Get("Disconnected");
        }
    }

    // Credential fields auto-apply on edit (bindings update on focus loss), matching
    // the live-apply behavior of every other control in this window.
    partial void OnIpAddressChanged(string value)
    {
        _settings.IpAddress = value.Trim();
        RefreshCertState();
    }

    partial void OnApiKeyChanged(string value) => _settings.ApiKey = value.Trim();
    partial void OnUsernameChanged(string value) { _settings.Username = value.Trim(); RefreshBadge(); }
    partial void OnPasswordChanged(string value) { _settings.Password = value; RefreshBadge(); }

    partial void OnShowFocusOverlayControlsChanged(bool value) => _settings.ShowFocusOverlayControls = value;

    // App subscribes to AppSettings.Appearance and updates RequestedThemeVariant live.
    partial void OnAppearanceIndexChanged(int value)
        => _settings.Appearance = (AppSettings.AppearanceMode)Math.Clamp(value, 0, 2);

    partial void OnAccentIndexChanged(int value)
    {
        if (value < 0 || value >= AccentHexes.Length) return;
        _settings.AccentColorHex = AccentHexes[value];
        (Avalonia.Application.Current as App)?.ApplyAccent(AccentHexes[value]);
    }

    partial void OnSnapshotDestinationIndexChanged(int value)
        => _settings.SnapshotDest = (AppSettings.SnapshotDestination)Math.Clamp(value, 0, 1);

    [RelayCommand]
    private async Task ChooseSnapshotFolder()
    {
        if (PickFolderAsync is null) return;
        var picked = await PickFolderAsync();
        if (string.IsNullOrEmpty(picked)) return;
        _settings.SnapshotFolder = picked;
        SnapshotFolderDisplay = picked;
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
        HotkeyDisplay = Localization.Loc.Get("Press a key combination…");
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
            StatusMessage = Localization.Loc.Get("Unsupported key — use a letter, number, or function key.");
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
    private async Task TestConnection()
    {
        _settings.IpAddress = IpAddress.Trim();
        _settings.ApiKey = ApiKey.Trim();
        await _service.FetchCamerasAsync(forced: true);
        RefreshCertState();
        StatusMessage = _service.ErrorMessage is { } err
            ? string.Format(Localization.Loc.Get("Error: {0}"), err)
            : Localization.Loc.Get("Connected — %lld cameras found")
                .Replace("%lld", _service.Cameras.Count.ToString());
    }

    /// <summary>Classic-API login check for the PTZ section (macOS runPtzTest).</summary>
    [RelayCommand]
    private async Task TestPtz()
    {
        PtzStatusMessage = Localization.Loc.Get("Signing in…");
        var ok = await _service.ClassicLoginAsync();
        PtzStatusMessage = ok
            ? Localization.Loc.Get("Signed in · PTZ control ready")
            : Localization.Loc.Get("Login failed — check the username and password");
        RefreshBadge();
    }

    [RelayCommand]
    private async Task CheckForUpdates()
    {
        UpdateStatusMessage = Localization.Loc.Get("Checking for updates…");
        await _updater.CheckForUpdateAsync();
        UpdateStatusMessage = _updater.UpdateAvailable
            ? string.Format(Localization.Loc.Get("Update available: {0}"), _updater.LatestVersion)
            : Localization.Loc.Get("You're on the latest version.");
    }

    [RelayCommand]
    private static void OpenGitHub()
        => UrlOpener.Open("https://github.com/cb2206/QuickProtect");

    [RelayCommand]
    private static void OpenLicense()
        => UrlOpener.Open("https://github.com/cb2206/QuickProtect/blob/main/LICENSE");

    [RelayCommand]
    private void OpenReleasePage()
        => UrlOpener.Open(_updater.ReleaseUrl ?? _updater.ReleasesPageUrl);

    [RelayCommand]
    private void TrustNewCertificate()
    {
        if (string.IsNullOrEmpty(_settings.IpAddress)) return;
        _trust.TrustPending(_settings.IpAddress);
        RefreshCertState();
        StatusMessage = Localization.Loc.Get("New certificate trusted.");
    }
}
