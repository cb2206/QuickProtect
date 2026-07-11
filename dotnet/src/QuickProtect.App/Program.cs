using Avalonia;
using LibVLCSharp.Shared;
using QuickProtect.Core.Services;

namespace QuickProtect.App;

internal static class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called.
    [STAThread]
    public static void Main(string[] args)
    {
        // Capture any fatal exception to a log file so crashes are diagnosable
        // without a console (WinExe apps have no attached console).
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash(e.ExceptionObject as Exception, "AppDomain");
        TaskScheduler.UnobservedTaskException += (_, e) => { LogCrash(e.Exception, "Task"); e.SetObserved(); };

        // Load the native libVLC libraries once, before any LibVLC object is created.
        // Windows ships them via NuGet; Linux uses the system 'vlc' package; on macOS
        // (where there's no arm64 libVLC NuGet) prefer a system VLC.app install.
        try
        {
            var macVlcLib = "/Applications/VLC.app/Contents/MacOS/lib";
            if (OperatingSystem.IsMacOS() && Directory.Exists(macVlcLib))
            {
                Environment.SetEnvironmentVariable("VLC_PLUGIN_PATH",
                    "/Applications/VLC.app/Contents/MacOS/plugins");
                LibVLCSharp.Shared.Core.Initialize(macVlcLib);
            }
            else
            {
                LibVLCSharp.Shared.Core.Initialize();
            }
        }
        catch (Exception ex) { Console.Error.WriteLine($"[libVLC] init failed: {ex.Message}"); }

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
