using Avalonia;
using LibVLCSharp.Shared;

namespace QuickProtect.App;

internal static class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called.
    [STAThread]
    public static void Main(string[] args)
    {
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

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
