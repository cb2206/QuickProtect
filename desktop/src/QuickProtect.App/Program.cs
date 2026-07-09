using Avalonia;
using QuickProtect.Core.Services;

namespace QuickProtect.App;

internal static class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called.
    /// <summary>Raw launch arguments (e.g. <c>--open-panel</c> opens the grid at startup).</summary>
    public static string[] LaunchArgs { get; private set; } = Array.Empty<string>();

    /// <summary>Signaled by a second launch to bring the running instance's panel up.</summary>
    public const string ShowPanelEventName = "QuickProtect-ShowPanel";

    [STAThread]
    public static void Main(string[] args)
    {
        LaunchArgs = args;

        // Single instance: the tray agent must never run twice (duplicate trays,
        // duplicate stream allocations). A second launch nudges the running
        // instance to show its panel instead, then exits.
        using var singleInstance = new Mutex(initiallyOwned: true, "QuickProtect-SingleInstance", out var isFirstInstance);
        if (!isFirstInstance)
        {
            if (OperatingSystem.IsWindows())
            {
                try { EventWaitHandle.OpenExisting(ShowPanelEventName).Set(); }
                catch { /* running instance is still starting up — nothing to signal */ }
            }
            return;
        }
        // Capture any fatal exception to a log file so crashes are diagnosable
        // without a console (WinExe apps have no attached console).
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash(e.ExceptionObject as Exception, "AppDomain");
        TaskScheduler.UnobservedTaskException += (_, e) => { LogCrash(e.Exception, "Task"); e.SetObserved(); };

        try
        {
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            LogCrash(ex, "Startup/UI");
            throw;
        }
    }

    /// <summary>Appends a crash to <c>%APPDATA%\QuickProtect\crash.log</c> (best effort).</summary>
    private static void LogCrash(Exception? ex, string source)
    {
        try
        {
            var path = Path.Combine(AppPaths.ConfigDirectory, "crash.log");
            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}\n{ex}\n\n");
        }
        catch { /* nothing we can do */ }
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
