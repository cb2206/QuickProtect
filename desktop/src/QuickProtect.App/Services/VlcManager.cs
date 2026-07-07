using System.Collections.Concurrent;
using LibVLCSharp.Shared;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Owns the single shared <see cref="LibVLC"/> instance. Each camera tile creates
/// its own <see cref="MediaPlayer"/> from it. libVLC handles RTSP/RTSPS, decode,
/// and rendering — this is what replaces the macOS app's hand-written RTSPClient
/// + RTPParser + VideoToolbox pipeline.
///
/// libVLC runs its own TLS stack (gnutls), independent of the app's
/// <c>CertificateTrust</c> HTTP pinning. A self-signed controller certificate
/// therefore triggers libVLC's "insecure site" question dialog; without a
/// registered dialog handler the connection is silently aborted and tiles stay
/// black. <see cref="SetupDialogHandlers"/> auto-accepts that dialog, but only
/// for hosts the app is deliberately streaming from — every stream URL comes
/// from the pinned-certificate controller API, so the host was already trusted
/// by the user via TOFU.
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

    /// <summary>
    /// TLS bridge for <c>rtsps://</c> URLs (VLC 3 can't open that scheme itself).
    /// Set once at startup; when null, rtsps URLs are passed through and will fail.
    /// </summary>
    public RtspTlsTunnel? Tunnel { get; set; }

    /// <summary>Hosts we intentionally opened streams to; cert dialogs for them are accepted.</summary>
    private readonly ConcurrentDictionary<string, byte> _streamingHosts = new(StringComparer.OrdinalIgnoreCase);

    private readonly object _logLock = new();
    private StreamWriter? _logWriter;

    private VlcManager()
    {
        try
        {
            // --no-osd: no on-screen libVLC overlays. Verbose off to keep logs quiet.
            // (On macOS the plugin location comes from VLC_PLUGIN_PATH, set in Program.cs —
            // libVLC 3 dropped the --plugin-path option.)
            LibVLC = new LibVLC("--no-osd", "--no-video-title-show");
            SetupFileLog(LibVLC);
            SetupDialogHandlers(LibVLC);
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
        // rtsps:// goes through the local TLS tunnel — VLC 3 has no rtsps module.
        var playable = Tunnel?.MapUrl(url) ?? url;
        var uri = new Uri(playable);
        if (uri.Host is { Length: > 0 } host) _streamingHosts.TryAdd(host, 0);
        var media = new Media(LibVLC, uri);
        media.AddOption(":rtsp-tcp");
        media.AddOption(":network-caching=300");
        return media;
    }

    // MARK: - Certificate question dialogs

    private void SetupDialogHandlers(LibVLC libvlc)
    {
        libvlc.SetDialogHandlers(
            error: (title, text) =>
            {
                Log.Line($"[libVLC dialog] error: {title}: {text}");
                return Task.CompletedTask;
            },
            login: (dialog, title, text, defaultUsername, askStore, token) =>
            {
                // Stream URLs carry their token; a login prompt is unexpected — abort.
                Log.Line($"[libVLC dialog] unexpected login prompt dismissed: {title}");
                dialog.Dismiss();
                return Task.CompletedTask;
            },
            question: (dialog, title, text, type, cancelText, firstActionText, secondActionText, token) =>
            {
                // gnutls raises two consecutive "Insecure site" questions for a
                // self-signed cert: (1) Abort / View certificate, (2) Abort /
                // Accept 24 hours / Accept permanently. In both, action 1 moves
                // forward. Accept only when the dialog is about a host we opened
                // a stream to (the message text embeds the hostname).
                var trusted = _streamingHosts.Keys.FirstOrDefault(h =>
                    text?.Contains(h, StringComparison.OrdinalIgnoreCase) == true);
                if (trusted != null)
                {
                    Log.Line($"[libVLC dialog] accepting certificate question for {trusted} ({firstActionText})");
                    dialog.PostAction(1);
                }
                else
                {
                    Log.Line($"[libVLC dialog] dismissed question for unknown host: {title}: {text}");
                    dialog.Dismiss();
                }
                return Task.CompletedTask;
            },
            displayProgress: (dialog, title, text, indeterminate, position, cancelText, token) => Task.CompletedTask,
            updateProgress: (dialog, position, text) => Task.CompletedTask);
    }

    // MARK: - Diagnostic log file

    /// <summary>
    /// Mirrors libVLC warnings/errors to <c>%APPDATA%\QuickProtect\vlc.log</c>
    /// (truncated each session) so stream/decoder failures are diagnosable in a
    /// WinExe build with no console.
    /// </summary>
    private void SetupFileLog(LibVLC libvlc)
    {
        try
        {
            var path = Path.Combine(AppPaths.ConfigDirectory, "vlc.log");
            _logWriter = new StreamWriter(path, append: false) { AutoFlush = true };
            _logWriter.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] libVLC {libvlc.Version}");
        }
        catch (Exception ex)
        {
            Log.Line($"[libVLC] log file unavailable: {ex.Message}");
            return;
        }

        // QP_VLC_DEBUG=1 captures everything (diagnosis); default is Warning+.
        var verbose = Environment.GetEnvironmentVariable("QP_VLC_DEBUG") == "1";
        libvlc.Log += (_, e) =>
        {
            if (!verbose && e.Level < LogLevel.Warning) return;
            lock (_logLock)
            {
                _logWriter?.WriteLine($"[{DateTime.Now:HH:mm:ss}] {e.Level} {e.Module}: {e.Message}");
            }
        };
    }

    public void Dispose()
    {
        LibVLC?.Dispose();
        lock (_logLock) { _logWriter?.Dispose(); _logWriter = null; }
    }
}
