using LibVLCSharp.Shared;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Captures a still frame from a playing <see cref="MediaPlayer"/> to a PNG via
/// libVLC's <c>TakeSnapshot</c>. Saves into the user-configured snapshot folder,
/// falling back to the OS Pictures folder.
///
/// Note: the macOS app can also place the image on the clipboard. Cross-platform
/// image-clipboard is a follow-up (see PARITY.md) — this writes a file for now.
/// </summary>
public static class SnapshotService
{
    public sealed record Result(bool Ok, string? Path, string Message);

    public static Result Capture(MediaPlayer? player, string cameraName)
    {
        if (player == null)
            return new Result(false, null, "Video is unavailable.");
        if (!player.IsPlaying)
            return new Result(false, null, "Camera isn't playing yet.");

        var dir = ResolveFolder();
        try { Directory.CreateDirectory(dir); }
        catch (Exception ex) { return new Result(false, null, $"Can't create folder: {ex.Message}"); }

        var path = Path.Combine(dir, SnapshotNaming.FileName(cameraName, DateTime.Now));
        try
        {
            // num=0 (first video output), width=height=0 → native resolution.
            var ok = player.TakeSnapshot(0, path, 0, 0);
            return ok
                ? new Result(true, path, $"Saved {Path.GetFileName(path)}")
                : new Result(false, null, "Snapshot failed.");
        }
        catch (Exception ex)
        {
            Log.Line($"[Snapshot] failed: {ex.Message}");
            return new Result(false, null, ex.Message);
        }
    }

    private static string ResolveFolder()
    {
        var configured = AppSettings.Shared.SnapshotFolder;
        if (!string.IsNullOrWhiteSpace(configured)) return configured!;
        var pics = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return Path.Combine(string.IsNullOrEmpty(pics) ? AppPaths.ConfigDirectory : pics, "QuickProtect");
    }
}
