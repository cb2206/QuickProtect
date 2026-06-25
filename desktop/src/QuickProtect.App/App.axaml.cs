using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using QuickProtect.App.Platform;
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

    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private SettingsWindow? _settingsWindow;

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        // Build the dependency graph (the equivalent of AppDelegate's stored properties).
        var prefs = new JsonFilePreferences();
        var secrets = SecretStore.Create();
        Settings = AppSettings.Configure(prefs, secrets);
        Settings.LaunchManager = LaunchAtLoginFactory.Create();
        Trust = new CertificateTrust(prefs);
        Service = new ProtectService(Settings, Trust);
        Service.CertificateChanged += (_, message) =>
            Dispatcher.UIThread.Post(() => Service_ShowError(message));

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Menu-bar / tray agent: no main window at startup, app keeps running
            // when all windows close (mirrors LSUIElement on macOS).
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            desktop.Exit += (_, _) => OnExit();
        }

        SetupTray();

        // Kick off an initial fetch when credentials already exist.
        if (!string.IsNullOrEmpty(Settings.IpAddress) && !string.IsNullOrEmpty(Settings.ApiKey))
            _ = Service.FetchCamerasAsync();

        if (!Settings.HasCompletedOnboarding)
            ShowSettings(); // onboarding wizard is a follow-up; Settings covers first-run config for now

        base.OnFrameworkInitializationCompleted();
    }

    private void SetupTray()
    {
        var menu = new NativeMenu();

        var open = new NativeMenuItem("Open QuickProtect");
        open.Click += (_, _) => ToggleMainWindow();
        menu.Add(open);

        var settings = new NativeMenuItem("Settings…");
        settings.Click += (_, _) => ShowSettings();
        menu.Add(settings);

        menu.Add(new NativeMenuItemSeparator());

        var quit = new NativeMenuItem("Quit QuickProtect");
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

    public void ShowSettings()
    {
        if (_settingsWindow == null)
        {
            _settingsWindow = new SettingsWindow { DataContext = new SettingsViewModel(Service, Settings, Trust) };
            _settingsWindow.Closing += (_, e) => { e.Cancel = true; _settingsWindow!.Hide(); };
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void Service_ShowError(string message)
    {
        // Lightweight surface for now; a styled alert is a follow-up.
        Console.Error.WriteLine($"[QuickProtect] {message}");
    }

    private void Shutdown()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.Shutdown();
    }

    private void OnExit()
    {
        // Release server-side stream allocations before the process dies.
        Service.CleanupStreams();
        Service.CleanupPinnedStreams();
        Service.Dispose();
    }
}
