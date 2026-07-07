using Avalonia;
using QuickProtect.Core.Services;

namespace QuickProtect.App;

internal static class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called.
    /// <summary>Raw launch arguments (e.g. <c>--open-panel</c> opens the grid at startup).</summary>
    public static string[] LaunchArgs { get; private set; } = Array.Empty<string>();

    [STAThread]
    public static void Main(string[] args)
    {
        LaunchArgs = args;
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
