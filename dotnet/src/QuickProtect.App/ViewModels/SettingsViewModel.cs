using System.Collections.ObjectModel;
using System.Reflection;
using Avalonia.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using QuickProtect.App.Platform;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>A changed controller certificate awaiting the user's decision, with both keys for out-of-band verification.</summary>
public sealed record PendingCertificate(string Host, string? TrustedFingerprint, string NewFingerprint)
{
    public bool HasTrustedFingerprint => TrustedFingerprint != null;
}

/// <summary>
/// Settings window: sidebar-sectioned (General / Connection / PTZ / Cameras /
/// Shortcuts / Updates) mirroring the macOS SettingsView. Every control writes
/// straight through to <see cref="AppSettings"/> (which persists to prefs/secret
/// store) — there is no explicit Save.
/// </summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ProtectHub _service;
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

    // MARK: Sites — the Connection and PTZ sections edit the selected site.

    public ObservableCollection<SiteRowViewModel> SiteRows { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PtzSectionCaption))]
    private int _selectedSiteIndex;

    /// <summary>More than one site: the PTZ section shows a site picker, Remove is offered.</summary>
    public bool HasMultipleSites => _settings.HasMultipleSites;

    private ControllerSite SelectedSite
        => SelectedSiteIndex >= 0 && SelectedSiteIndex < _settings.Sites.Count
            ? _settings.Sites[SelectedSiteIndex]
            : _settings.Sites[0];

    private ProtectService? SelectedService => _service.ServiceForSite(SelectedSite.Id);

    public string PtzSectionCaption => HasMultipleSites
        ? string.Format(Localization.Loc.Get("Classic API credentials · {0}"), SiteRows.ElementAtOrDefault(SelectedSiteIndex)?.DisplayName)
        : Localization.Loc.Get("Classic API credentials");

    /// <summary>Where on the console to create the API key / PTZ account (the "?" flyouts).</summary>
    public string ApiKeyHelp => Localization.Loc.Get("Create the key on this console, not at unifi.ui.com: open UniFi Network → Integrations → Create New API Key (on Network 9: Settings → Control Plane → Integrations). Each console needs its own key.");
    public string PtzAccountHelp => Localization.Loc.Get("Use a local account on this console: in UniFi OS open Admins & Users → Create New, tick “Restrict to Local Access Only”, and give it a Protect role that can control cameras.");

    /// <summary>Set by the window so removing a site can ask first.</summary>
    public Func<string, string, string, Task<bool>>? ConfirmAsync { get; set; }

    // Set while the fields are being loaded from another site, so the change
    // handlers don't write them into it.
    private bool _loadingSite;
    private ProtectService? _watchedService;

    [ObservableProperty] private string _siteName = "";
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

    /// <summary>Every host with a pending certificate — listed rather than one guessed key.</summary>
    public ObservableCollection<PendingCertificate> PendingCertificates { get; } = new();

    [ObservableProperty] private string _hotkeyDisplay = Localization.Loc.Get("Not set");
    [ObservableProperty] private string _hotkeyStatusMessage = "";
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

    public SettingsViewModel(ProtectHub service, AppSettings settings, CertificateTrust trust, UpdateChecker updater)
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

        // A hotkey the OS refused (already taken by another app) is reported
        // inline in the Shortcuts section.
        if (Avalonia.Application.Current is App app) app.HotkeyApplied += OnHotkeyApplied;

        var first = settings.Sites[0];
        _siteName = first.Name;
        _ipAddress = first.IpAddress;
        _apiKey = first.ApiKey;
        _username = first.Username;
        _password = first.Password;
        RebuildSiteRows();
        WatchSelectedService();
        settings.SitesChanged += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RebuildSiteRows);
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
            if (e.PropertyName is nameof(ProtectHub.SiteIssues) or nameof(ProtectHub.Cameras))
                Avalonia.Threading.Dispatcher.UIThread.Post(() => { RefreshSiteRows(); RefreshBadge(); });
            // A certificate trusted from the panel or a pinned window (or a new
            // rejection) must not leave this section stale while Settings is open.
            else if (e.PropertyName is nameof(ProtectHub.PendingCertificateChange))
                Avalonia.Threading.Dispatcher.UIThread.Post(RefreshCertState);
        };
    }

    // MARK: - Sites

    private void RebuildSiteRows()
    {
        var keep = SelectedSite.Id;
        SiteRows.Clear();
        foreach (var site in _settings.Sites) SiteRows.Add(new SiteRowViewModel(site));
        RefreshSiteRows();
        OnPropertyChanged(nameof(HasMultipleSites));
        var idx = _settings.Sites.ToList().FindIndex(s => s.Id == keep);
        // Clamp: the selection index moves when a site before it is removed.
        SelectedSiteIndex = idx < 0 ? 0 : idx;
        OnPropertyChanged(nameof(PtzSectionCaption));
    }

    private void RefreshSiteRows()
    {
        foreach (var row in SiteRows) row.Refresh(_service.ServiceForSite(row.Site.Id));
        OnPropertyChanged(nameof(PtzSectionCaption));
    }

    partial void OnSelectedSiteIndexChanged(int value)
    {
        if (value < 0) return;
        var site = SelectedSite;
        _loadingSite = true;
        SiteName = site.Name;
        IpAddress = site.IpAddress;
        ApiKey = site.ApiKey;
        Username = site.Username;
        Password = site.Password;
        _loadingSite = false;
        // The last test result was for another console.
        StatusMessage = "";
        PtzStatusMessage = "";
        WatchSelectedService();
        RefreshBadge();
    }

    /// <summary>The header badge follows the selected site's own service (login state isn't merged).</summary>
    private void WatchSelectedService()
    {
        if (_watchedService != null) _watchedService.PropertyChanged -= OnSelectedServiceChanged;
        _watchedService = SelectedService;
        if (_watchedService != null) _watchedService.PropertyChanged += OnSelectedServiceChanged;
    }

    private void OnSelectedServiceChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ProtectService.ErrorMessage) or nameof(ProtectService.Cameras)
            or nameof(ProtectService.IsClassicLoggedIn))
            Avalonia.Threading.Dispatcher.UIThread.Post(() => { RefreshSiteRows(); RefreshBadge(); });
    }

    [RelayCommand]
    private void AddSite()
    {
        var site = _settings.AddSite();
        RebuildSiteRows();
        SelectedSiteIndex = _settings.Sites.ToList().FindIndex(s => s.Id == site.Id);
    }

    [RelayCommand]
    private async Task RemoveSite()
    {
        if (!_settings.HasMultipleSites) return;
        var site = SelectedSite;
        var label = site.DisplayName.Length > 0 ? site.DisplayName : Localization.Loc.Get("New Site");
        if (ConfirmAsync != null && !await ConfirmAsync(
                string.Format(Localization.Loc.Get("Remove “{0}”?"), label),
                Localization.Loc.Get("Its cameras disappear from every profile, and its API key and login are deleted from this computer."),
                Localization.Loc.Get("Remove")))
            return;
        _settings.RemoveSite(site.Id);
        RebuildSiteRows();
        SelectedSiteIndex = 0;
    }

    partial void OnSiteNameChanged(string value)
    {
        if (_loadingSite) return;
        SelectedSite.Name = value.Trim();
        RefreshSiteRows();
    }

    partial void OnSelectedSectionIndexChanged(int value) => RefreshBadge();

    private void RefreshBadge()
    {
        if (SelectedSectionIndex == SectionPtz)
        {
            var configured = !string.IsNullOrEmpty(Username) && !string.IsNullOrEmpty(Password);
            var loggedIn = SelectedService?.IsClassicLoggedIn ?? false;
            BadgeConnected = loggedIn;
            BadgeText = loggedIn
                ? Localization.Loc.Get("Connected")
                : configured ? Localization.Loc.Get("Not verified") : Localization.Loc.Get("Not configured");
        }
        else if (SelectedSectionIndex == SectionConnection)
        {
            // The selected site on the Connection section.
            var service = SelectedService;
            var healthy = service is { ErrorMessage: null, CertificateChange: null };
            BadgeConnected = healthy && service!.Cameras.Count > 0;
            BadgeText = !SelectedSite.IsConfigured
                ? Localization.Loc.Get("Not configured")
                : Localization.Loc.Get(healthy ? "Connected" : "Disconnected");
        }
        else
        {
            // Everywhere else: all sites.
            var healthy = _service.SiteIssues.Count == 0;
            BadgeConnected = healthy && _service.Cameras.Count > 0;
            BadgeText = Localization.Loc.Get(healthy ? "Connected" : "Disconnected");
        }
    }

    // Credential fields auto-apply on edit (bindings update on focus loss), matching
    // the live-apply behavior of every other control in this window.
    partial void OnIpAddressChanged(string value)
    {
        if (_loadingSite) return;
        SelectedSite.IpAddress = value.Trim();
        RefreshSiteRows();
        RefreshCertState();
    }

    partial void OnApiKeyChanged(string value) { if (!_loadingSite) SelectedSite.ApiKey = value.Trim(); }
    partial void OnUsernameChanged(string value) { if (_loadingSite) return; SelectedSite.Username = value.Trim(); RefreshBadge(); }
    partial void OnPasswordChanged(string value) { if (_loadingSite) return; SelectedSite.Password = value; RefreshBadge(); }

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
            HotkeyStatusMessage = Localization.Loc.Get("Unsupported key — use a letter, number, or function key.");
            return;
        }
        var mod = HotkeyCodec.Modifiers(modifiers);
        if (mod == 0)
        {
            // A bare key registered system-wide would swallow that key in every
            // app (macOS parity: the recorder requires a modifier there too).
            HotkeyStatusMessage = Localization.Loc.Get("Add a modifier key (Ctrl, Alt, Shift or Win) to the shortcut.");
            return;
        }
        HotkeyStatusMessage = "";
        _settings.SetGlobalHotkey(vk, mod);
        IsRecordingHotkey = false;
        RefreshHotkey();
    }

    /// <summary>Called by the app after each (re)registration; a refusal is shown inline.</summary>
    public void OnHotkeyApplied(bool registered)
    {
        if (!registered)
            HotkeyStatusMessage = Localization.Loc.Get("Couldn't register this shortcut — it may be in use by another app.");
    }

    partial void OnDefaultQualityIndexChanged(int value)
        => _settings.DefaultStreamQuality = (StreamQuality)Math.Clamp(value, 0, 3);

    partial void OnLaunchAtLoginChanged(bool value) => _settings.LaunchAtLogin = value;

    private void RefreshCertState()
    {
        PendingCertificates.Clear();
        foreach (var (host, fingerprint) in _trust.AllPending())
        {
            var pinned = _trust.Pinned(host);
            PendingCertificates.Add(new PendingCertificate(
                host,
                pinned == null ? null : CertificateTrust.DisplayFingerprint(pinned, bytesPerLine: 16),
                CertificateTrust.DisplayFingerprint(fingerprint, bytesPerLine: 16)));
        }
        HasPendingCert = PendingCertificates.Count > 0;
    }

    [RelayCommand]
    private async Task TestConnection()
    {
        // Store the address in its canonical form (scheme, path and whitespace
        // dropped) so what the user sees is exactly what gets pinned and dialled.
        var site = SelectedSite;
        site.IpAddress = ControllerAddress.Parse(IpAddress)?.Authority ?? IpAddress.Trim();
        IpAddress = site.IpAddress;
        site.ApiKey = ApiKey.Trim();
        // Another site already points at this console: its cameras would
        // collide with this one's and show once.
        var mine = ControllerAddress.Parse(site.IpAddress)?.Authority;
        if (mine != null && _settings.Sites.FirstOrDefault(o => o.Id != site.Id
                && ControllerAddress.Parse(o.IpAddress)?.Authority == mine) is { } duplicate)
        {
            StatusMessage = string.Format(Localization.Loc.Get("This console is already added as “{0}”."), duplicate.DisplayName);
            return;
        }
        var service = _service.ServiceForSite(site.Id);
        if (service != null) await service.FetchCamerasAsync(forced: true);
        _service.Recompute();
        RefreshCertState();
        RefreshSiteRows();
        RefreshBadge();
        StatusMessage = service?.ErrorMessage is { } err
            ? string.Format(Localization.Loc.Get("Error: {0}"), Localization.Loc.Get(err))
            : Localization.Loc.Get("Connected — %lld cameras found")
                .Replace("%lld", (service?.Cameras.Count ?? 0).ToString());
    }

    /// <summary>Classic-API login check for the PTZ section (macOS runPtzTest).</summary>
    [RelayCommand]
    private async Task TestPtz()
    {
        PtzStatusMessage = Localization.Loc.Get("Signing in…");
        var ok = SelectedService is { } service && await service.ClassicLoginAsync();
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
    private void TrustNewCertificate(string? host)
    {
        if (string.IsNullOrEmpty(host)) return;
        // Through the service, so the panel's card clears, the camera list is
        // fetched again and failed streams restart (see App).
        _service.TrustPendingCertificate(host);
        RefreshCertState();
        StatusMessage = Localization.Loc.Get("New certificate trusted.");
    }
}
