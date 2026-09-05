using System.Runtime.InteropServices;
using FFmpeg.AutoGen.Abstractions;
using FFmpeg.AutoGen.Bindings.DynamicallyLoaded;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Video;

/// <summary>
/// Loads the FFmpeg native libraries and holds engine-wide state for the custom
/// video pipeline (the port's analog of the macOS RTSPClient + VideoToolbox
/// stack). Replaces libVLC: FFmpeg demuxes RTSP and decodes H.264/H.265, frames
/// are composited by <see cref="VideoSurface"/> inside Avalonia — no native
/// child windows, so video is clickable, gesture-capable, and overlayable.
///
/// Native libraries are bundled per-RID under <c>ffmpeg/</c> next to the app
/// (see scripts/get-ffmpeg.ps1) — including native win-arm64. When absent, the
/// system-installed FFmpeg is used (Linux distro packages).
/// </summary>
public static class FfmpegEngine
{
    /// <summary>False when the natives failed to load — the app runs without video.</summary>
    public static bool IsAvailable { get; private set; }

    /// <summary>TLS bridge for rtsps:// URLs, sharing the API's TOFU pinning.</summary>
    public static RtspTlsTunnel? Tunnel { get; set; }

    private const string HomebrewFfmpegLib = "/opt/homebrew/opt/ffmpeg/lib";

    private static StreamWriter? _logWriter;
    private static readonly object _logLock = new();
    private static av_log_set_callback_callback? _logCallback; // keep delegate alive

    public static void Initialize()
    {
        try
        {
            var bundled = Path.Combine(AppContext.BaseDirectory, "ffmpeg");
            if (Directory.Exists(bundled))
                DynamicallyLoadedBindings.LibrariesPath = bundled;
            else if (OperatingSystem.IsMacOS() && Directory.Exists(HomebrewFfmpegLib))
                // Development only (macOS isn't a shipping target for this port):
                // dlopen doesn't search Homebrew's prefix, so point at it when
                // the natives aren't bundled.
                DynamicallyLoadedBindings.LibrariesPath = HomebrewFfmpegLib;
            DynamicallyLoadedBindings.Initialize();

            ffmpeg.av_log_set_level(ffmpeg.AV_LOG_WARNING);
            SetupFileLog();
            IsAvailable = true;
            Log.Line($"[Video] FFmpeg {ffmpeg.av_version_info()} loaded" +
                     (Directory.Exists(bundled) ? $" from {bundled}" : " from system"));
        }
        catch (Exception ex)
        {
            IsAvailable = false;
            Log.Line($"[Video] FFmpeg unavailable — video disabled: {ex.Message}");
        }
    }

    /// <summary>Map an rtsps:// URL through the TLS tunnel (FFmpeg gets plain rtsp).</summary>
    public static string MapUrl(string url) => Tunnel?.MapUrl(url) ?? url;

    /// <summary>
    /// Mirrors FFmpeg warnings/errors to <c>%APPDATA%\QuickProtect\video.log</c>
    /// (truncated per session).
    /// </summary>
    private static unsafe void SetupFileLog()
    {
        try
        {
            var path = Path.Combine(AppPaths.ConfigDirectory, "video.log");
            _logWriter = new StreamWriter(path, append: false) { AutoFlush = true };
            _logWriter.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] FFmpeg {ffmpeg.av_version_info()}");
        }
        catch (Exception ex)
        {
            Log.Line($"[Video] log file unavailable: {ex.Message}");
            return;
        }

        _logCallback = (p0, level, format, vl) =>
        {
            if (level > ffmpeg.av_log_get_level()) return;
            const int size = 1024;
            var buffer = stackalloc byte[size];
            var printPrefix = 1;
            ffmpeg.av_log_format_line(p0, level, format, vl, buffer, size, &printPrefix);
            var line = Marshal.PtrToStringAnsi((IntPtr)buffer)?.TrimEnd();
            if (string.IsNullOrEmpty(line)) return;
            lock (_logLock) { _logWriter?.WriteLine($"[{DateTime.Now:HH:mm:ss}] {line}"); }
        };
        ffmpeg.av_log_set_callback(_logCallback);
    }
}
