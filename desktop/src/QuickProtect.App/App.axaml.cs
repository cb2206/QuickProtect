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
    private SettingsWindow? _settingsWindow;
    private OnboardingWindow? _onboardingWindow;
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
        Video.FfmpegEngine.Tunnel = new RtspTlsTunnel(Trust);
        Streams = new Video.VideoStreamCoordinator(Service);
        Service.CertificateChanged += (_, message) =>
            Dispatcher.UIThread.Post(() => Service_ShowError(message));
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
        Settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == "GlobalHotkey") Dispatcher.UIThread.Post(ApplyHotkey);
            if (e.PropertyName == nameof(AppSettings.Appearance))
                Dispatcher.UIThread.Post(() => ApplyAppearance(Settings.Appearance));
        };

        // Kick off an initial fetch when credentials already exist.
        if (!string.IsNullOrEmpty(Settings.IpAddress) && !string.IsNullOrEmpty(Settings.ApiKey))
            _ = Service.FetchCamerasAsync();

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
            _onboardingWindow = null;
            ToggleMainWindow(); // open the grid right after setup
        };
        _onboardingWindow = window;
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

    private void ApplyHotkey()
    {
        var hk = Settings.GlobalHotkey();
        _hotkey?.Update(hk?.keyCode, hk?.modifiers);
    }

    private void Service_ShowError(string message)
    {
        // Lightweight surface for now; a styled alert is a follow-up.
        Console.Error.WriteLine($"[QuickProtect] {message}");
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
        // Release server-side stream allocations before the process dies.
        _hotkey?.Dispose();
        Updater.Dispose();
        PinnedWindows.CloseAll();
        Streams.Dispose();
        Service.CleanupStreams();
        Service.CleanupPinnedStreams();
        Service.Dispose();
        Video.FfmpegEngine.Tunnel?.Dispose();
    }
}
