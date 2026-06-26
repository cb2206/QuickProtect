using LibVLCSharp.Shared;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Owns the single shared <see cref="LibVLC"/> instance. Each camera tile creates
/// its own <see cref="MediaPlayer"/> from it. libVLC handles RTSP/RTSPS, decode,
/// and rendering — this is what replaces the macOS app's hand-written RTSPClient
/// + RTPParser + VideoToolbox pipeline.
///
/// If the native libVLC fails to instantiate (e.g. missing/mismatched binaries),
/// <see cref="LibVLC"/> stays null and <see cref="IsAvailable"/> is false — the
/// app then runs without video instead of crashing.
/// </summary>
public sealed class VlcManager : IDisposable
{
    public static VlcManager Shared { get; } = new();

    public LibVLC? LibVLC { get; }
    public bool IsAvailable => LibVLC != null;

    private VlcManager()
    {
        try
        {
            // --no-osd: no on-screen libVLC overlays. Verbose off to keep logs quiet.
            var options = new List<string> { "--no-osd", "--no-video-title-show" };
            // On macOS we load libVLC from a system VLC.app; point it at the plugins.
            var macPlugins = "/Applications/VLC.app/Contents/MacOS/plugins";
            if (OperatingSystem.IsMacOS() && Directory.Exists(macPlugins))
                options.Add($"--plugin-path={macPlugins}");

            LibVLC = new LibVLC(options.ToArray());
        }
        catch (Exception ex)
        {
            // No video this session, but the rest of the app (camera list, settings,
            // PTZ, pins) keeps working.
            Log.Line($"[libVLC] unavailable — video disabled: {ex.Message}");
            LibVLC = null;
        }
    }

    /// <summary>
    /// Builds a <see cref="Media"/> for an RTSP/RTSPS URL with low-latency options:
    /// force TCP transport (UDP is often dropped by the controller) and a small
    /// network cache to keep the feed close to live. Null when libVLC is unavailable.
    /// </summary>
    public Media? MakeMedia(string url)
    {
        if (LibVLC == null) return null;
        var media = new Media(LibVLC, new Uri(url));
        media.AddOption(":rtsp-tcp");
        media.AddOption(":network-caching=300");
        return media;
    }

    public void Dispose() => LibVLC?.Dispose();
}
