using LibVLCSharp.Shared;

namespace QuickProtect.App.Services;

/// <summary>
/// Owns the single shared <see cref="LibVLC"/> instance. Each camera tile creates
/// its own <see cref="MediaPlayer"/> from it. libVLC handles RTSP/RTSPS, decode,
/// and rendering — this is what replaces the macOS app's hand-written RTSPClient
/// + RTPParser + VideoToolbox pipeline.
/// </summary>
public sealed class VlcManager : IDisposable
{
    public static VlcManager Shared { get; } = new();

    public LibVLC LibVLC { get; }

    private VlcManager()
    {
        // --no-osd: no on-screen libVLC overlays. Verbose off to keep logs quiet.
        LibVLC = new LibVLC("--no-osd", "--no-video-title-show");
    }

    /// <summary>
    /// Builds a <see cref="Media"/> for an RTSP/RTSPS URL with low-latency options:
    /// force TCP transport (UDP is often dropped by the controller) and a small
    /// network cache to keep the feed close to live.
    /// </summary>
    public Media MakeMedia(string url)
    {
        var media = new Media(LibVLC, new Uri(url));
        media.AddOption(":rtsp-tcp");
        media.AddOption(":network-caching=300");
        return media;
    }

    public void Dispose() => LibVLC.Dispose();
}
