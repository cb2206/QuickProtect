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
        // On Windows these ship via the VideoLAN.LibVLC.Windows package; on Linux
        // they come from the system 'vlc' package.
        try { LibVLCSharp.Shared.Core.Initialize(); }
        catch (Exception ex) { Console.Error.WriteLine($"[libVLC] init failed: {ex.Message}"); }

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
