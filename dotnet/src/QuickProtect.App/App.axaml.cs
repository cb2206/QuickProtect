using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Threading;
using QuickProtect.App.Platform;
using QuickProtect.App.Services;
using QuickProtect.App.ViewModels;
using QuickProtect.App.Views;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App;

public partial class App : Application
{
    public static App Instance => (App)Current!;

    public AppSettings Settings { get; private set; } = null!;
    public ProtectService Service { get; private set; } = null!;
    public CertificateTrust Trust { get; private set; } = null!;
    public PinnedWindowManager PinnedWindows { get; private set; } = null!;
    public UpdateChecker Updater { get; private set; } = null!;
    /// <summary>Shared per-camera stream clients (the macOS RTSPClientManager analog).</summary>
    public Video.VideoStreamCoordinator Streams { get; private set; } = null!;

    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    /// <summary>Pending deferred stream teardown while the keep-alive grace period
    /// runs (see <see cref="PanelClosed"/>). Cancelled when the panel reopens in time.</summary>
    private DispatcherTimer? _streamTeardownTimer;
    private SettingsWindow? _settingsWindow;
    private IGlobalHotkey? _hotkey;

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        // Build the dependency graph (the equivalent of AppDelegate's stored properties).
        var prefs = new JsonFilePreferences();
        var secrets = SecretStore.Create();
        Settings = AppSettings.Configure(prefs, secrets);
        Settings.LaunchManager = LaunchAtLoginFactory.Create();
        // Apply UI culture before any window/tray is built so localized strings resolve.
        Localization.Loc.ApplyCulture(Settings.LanguageOverride);
        ApplyAccent(Settings.AccentColorHex);
        ApplyAppearance(Settings.Appearance);
        Trust = new CertificateTrust(prefs);
        Service = new ProtectService(Settings, Trust);
        // Custom FFmpeg video engine; rtsps rides the local TLS bridge with the
        // same TOFU trust as the API.
        Video.FfmpegEngine.Initialize();
        // The tunnel pins under the configured controller identity, not under
        // whatever host the stream URL names, so video and API share one pin.
        Video.FfmpegEngine.Tunnel = new RtspTlsTunnel(Trust,
            connectHost => ControllerAddress.Parse(Settings.IpAddress)?.PinKey ?? connectHost);
        Streams = new Video.VideoStreamCoordinator(Service);
        // A rejection on the RTSPS tunnel has no API call to attach an error to;
        // surface it on the panel so the user knows why every tile is dead.
        Trust.Rejected += _ => Dispatcher.UIThread.Post(Service.ShowCertificateRejected);
        PinnedWindows = new PinnedWindowManager(Service, Settings);
        Updater = new UpdateChecker(CurrentVersion());
        Updater.StartPeriodicChecks();

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Menu-bar / tray agent: no main window at startup, app keeps running
            // when all windows close (mirrors LSUIElement on macOS).
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            desktop.Exit += (_, _) => OnExit();
        }

        SetupTray();

        // Global hotkey toggles the panel; re-applied whenever the binding changes.
        _hotkey = GlobalHotkeyFactory.Create(ToggleMainWindow);
        ApplyHotkey();
        // A controller/API-key change invalidates live streams and any pending
        // keep-alive grace — stale clients would keep talking to the old host.
        // The setters raise on every write (Settings re-applies unchanged text
        // on focus loss), so only an actual value change tears down.
        var lastIp = Settings.IpAddress;
        var lastApiKey = Settings.ApiKey;
        Settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == "GlobalHotkey") Dispatcher.UIThread.Post(ApplyHotkey);
            if (e.PropertyName == nameof(AppSettings.Appearance))
                Dispatcher.UIThread.Post(() => ApplyAppearance(Settings.Appearance));
            if (e.PropertyName == nameof(AppSettings.IpAddress) && Settings.IpAddress != lastIp)
            {
                lastIp = Settings.IpAddress;
                Dispatcher.UIThread.Post(TeardownStreamsNow);
            }
            if (e.PropertyName == nameof(AppSettings.ApiKey) && Settings.ApiKey != lastApiKey)
            {
                lastApiKey = Settings.ApiKey;
                Dispatcher.UIThread.Post(TeardownStreamsNow);
            }
        };

        // Kick off an initial fetch when credentials already exist.
        if (!string.IsNullOrEmpty(Settings.IpAddress) && !string.IsNullOrEmpty(Settings.ApiKey))
            _ = Service.FetchCamerasAsync();

        // A second app launch signals this event instead of starting (see Program).
        if (OperatingSystem.IsWindows()) StartShowPanelListener();

        if (!Settings.HasCompletedOnboarding)
            ShowOnboarding();
        else if (Program.LaunchArgs.Contains("--open-panel"))
            // Debug/testing affordance: open the camera panel immediately.
            Dispatcher.UIThread.Post(ToggleMainWindow);
        else if (Program.LaunchArgs.Contains("--open-settings"))
            Dispatcher.UIThread.Post(ShowSettings);

        base.OnFrameworkInitializationCompleted();
    }

    private void SetupTray()
    {
        var menu = new NativeMenu();

        var open = new NativeMenuItem(Localization.Loc.Get("Open QuickProtect"));
        open.Click += (_, _) => ToggleMainWindow();
        menu.Add(open);

        var settings = new NativeMenuItem(Localization.Loc.Get("Settings…"));
        settings.Click += (_, _) => ShowSettings();
        menu.Add(settings);

        menu.Add(new NativeMenuItemSeparator());

        var quit = new NativeMenuItem(Localization.Loc.Get("Quit QuickProtect"));
        quit.Click += (_, _) => Shutdown();
        menu.Add(quit);

        _tray = new TrayIcon
        {
            Icon = ApertureIcon.Create(),
            ToolTipText = "QuickProtect",
            Menu = menu,
            IsVisible = true
        };
        // Left-click opens the camera panel (right-click shows the menu natively).
        _tray.Clicked += (_, _) => ToggleMainWindow();
    }

    /// <summary>Waits for the single-instance "show panel" signal from duplicate launches.</summary>
    private void StartShowPanelListener()
    {
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset, Program.ShowPanelEventName);
        var thread = new Thread(() =>
        {
            while (signal.WaitOne())
                Dispatcher.UIThread.Post(ShowMainWindow);
        })
        { IsBackground = true, Name = "QP-ShowPanel" };
        thread.Start();
    }

    /// <summary>Show (never hide) the camera panel — used by external activation.</summary>
    private void ShowMainWindow()
    {
        if (_mainWindow is { IsVisible: true })
        {
            _mainWindow.Activate();
            return;
        }
        ToggleMainWindow();
    }

    private void ToggleMainWindow()
    {
        if (_mainWindow is { IsVisible: true })
        {
            _mainWindow.Hide();
            return;
        }
        // A tray click first deactivates the panel (outside-click dismiss fires),
        // then lands here — reopening would make the tray icon impossible to
        // use as a toggle. Treat a click right after an auto-hide as "close".
        if (_mainWindow != null && (DateTime.UtcNow - _mainWindow.LastAutoHide).TotalMilliseconds < 400)
            return;
        if (_mainWindow == null)
        {
            _mainWindow = new MainWindow { DataContext = new MainViewModel(Service, Settings) };
            _mainWindow.Closing += (_, e) =>
            {
                // Hide instead of destroy so streams can be torn down on hide.
                e.Cancel = true;
                _mainWindow!.Hide();
            };
        }
        _mainWindow.Show();
        _mainWindow.Activate();
        _ = Service.FetchCamerasAsync();
    }

    private void ShowOnboarding()
    {
        var vm = new OnboardingViewModel(Service, Settings);
        var window = new OnboardingWindow { DataContext = vm };
        vm.Finished += (_, _) =>
        {
            window.Close();
            ToggleMainWindow(); // open the grid right after setup
        };
        window.Show();
        window.Activate();
    }

    public void ShowSettings()
    {
        if (_settingsWindow == null)
        {
            _settingsWindow = new SettingsWindow { DataContext = new SettingsViewModel(Service, Settings, Trust, Updater) };
            _settingsWindow.Closing += (_, e) => { e.Cancel = true; _settingsWindow!.Hide(); };
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private static string CurrentVersion()
    {
        var v = typeof(App).Assembly.GetName().Version;
        return v == null ? "0.0" : $"{v.Major}.{v.Minor}.{v.Build}";
    }

    /// <summary>
    /// Apply the user's accent color to the Fluent theme (accent buttons, checkboxes,
    /// combo selection). Mirrors the macOS app's customizable accent.
    /// </summary>
    public void ApplyAccent(string hex)
    {
        var value = hex.StartsWith('#') ? hex : "#" + hex;
        if (!Color.TryParse(value, out var c)) return;
        // Set the base accent and its tint/shade variants Fluent derives states from.
        foreach (var key in new[]
                 {
                     "SystemAccentColor", "SystemAccentColorLight1", "SystemAccentColorLight2",
                     "SystemAccentColorLight3", "SystemAccentColorDark1", "SystemAccentColorDark2",
                     "SystemAccentColorDark3"
                 })
            Resources[key] = c;

        // Aurora accent-derived brushes (referenced via DynamicResource in views so
        // an accent change repaints live).
        Resources["QpAccent"] = new SolidColorBrush(c);
        Resources["QpAccentText"] = new SolidColorBrush(c);
        Resources["QpAccentSurface"] = new SolidColorBrush(Color.FromArgb(59, c.R, c.G, c.B));   // 23%
        Resources["QpAccentStrong"] = new SolidColorBrush(Color.FromArgb(204, c.R, c.G, c.B));   // 80%
    }

    /// <summary>
    /// Map the persisted appearance setting onto Avalonia's theme variant.
    /// Auto follows the OS; the video subtrees stay pinned dark via ThemeVariantScope.
    /// </summary>
    public void ApplyAppearance(AppSettings.AppearanceMode mode)
        => RequestedThemeVariant = mode switch
        {
            AppSettings.AppearanceMode.Light => ThemeVariant.Light,
            AppSettings.AppearanceMode.Dark => ThemeVariant.Dark,
            _ => ThemeVariant.Default
        };

    /// <summary>Raised after each hotkey (re)registration with whether the OS accepted it.</summary>
    public event Action<bool>? HotkeyApplied;

    private void ApplyHotkey()
    {
        var hk = Settings.GlobalHotkey();
        var ok = _hotkey?.Update(hk?.keyCode, hk?.modifiers) ?? true;
        HotkeyApplied?.Invoke(ok);
    }

    // MARK: - Stream keep-alive (the macOS scheduleStreamTeardown / teardownStreamsNow)

    /// <summary>
    /// Panel reopened: cancel any pending grace teardown so the still-connected
    /// streams are reused (the fresh tiles re-attach via the coordinator), and
    /// resume decode — each client burst-replays its buffered GOP so the picture
    /// is live immediately (no-op when nothing was paused).
    /// </summary>
    public void PanelOpened()
    {
        CancelStreamTeardown();
        Streams.SetRenderPaused(false);
    }

    /// <summary>
    /// Panel hidden: tear streams down after the configured grace period instead
    /// of at close, so a quick reopen shows video instantly and skips the fetch +
    /// per-camera POST/DELETE churn that can trip the controller's 10 req/s
    /// limit. A grace of 0 keeps the previous close-immediately behavior.
    /// </summary>
    public void PanelClosed(MainViewModel vm)
    {
        CancelStreamTeardown();
        var grace = Settings.StreamKeepAliveSeconds;
        if (grace <= 0)
        {
            TeardownStreamsNow();
            return;
        }
        // Motion and audio stop at close (macOS destroys the view tree here);
        // the streams and tile claims survive for the deferred teardown.
        vm.QuiesceForHide();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(grace) };
        timer.Tick += (_, _) => TeardownStreamsNow();
        _streamTeardownTimer = timer;
        timer.Start();
        // The streams survive but nobody sees them — stop decoding until the
        // panel reopens (each client buffers its current GOP for instant
        // resume), unless the user opted out in Settings.
        if (Settings.PauseDecodeWhileClosed)
            Streams.SetRenderPaused(true);
    }

    /// <summary>
    /// Immediate stream teardown: the in-flight camera fetch, all tile streams,
    /// and the server-side allocations (DELETE per stream). Runs on grace
    /// expiry, app quit, and connection-settings changes.
    /// </summary>
    public void TeardownStreamsNow()
    {
        CancelStreamTeardown();
        Service.CancelFetch();
        // Reset the pause flag so a client that restarts later decodes again.
        Streams.SetRenderPaused(false);
        if (_mainWindow?.DataContext is MainViewModel vm)
        {
            vm.StopAll();
        }
        else
        {
            Streams.ReleaseAllExceptPinned();
            Service.CleanupStreams();
        }
    }

    private void CancelStreamTeardown()
    {
        _streamTeardownTimer?.Stop();
        _streamTeardownTimer = null;
    }

    /// <summary>Quit the app (tray menu and the panel header's power button).</summary>
    public void RequestShutdown() => Shutdown();

    private void Shutdown()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.Shutdown();
    }

    private void OnExit()
    {
        // Release server-side stream allocations before the process dies. The
        // keep-alive grace doesn't apply on quit — flush it immediately.
        CancelStreamTeardown();
        Service.CancelFetch();
        _hotkey?.Dispose();
        Updater.Dispose();
        PinnedWindows.CloseAll();
        Streams.Dispose();
        // Give the DELETEs a moment to reach the controller before the
        // HttpClient goes away with them; bounded so quit never hangs.
        var released = Task.WhenAll(Service.CleanupStreams(), Service.CleanupPinnedStreams());
        try { released.Wait(TimeSpan.FromSeconds(2)); } catch { /* best effort on exit */ }
        Service.Dispose();
        Video.FfmpegEngine.Tunnel?.Dispose();
    }
}
