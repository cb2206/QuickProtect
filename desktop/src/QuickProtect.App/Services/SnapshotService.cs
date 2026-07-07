using LibVLCSharp.Shared;
using QuickProtect.App.Platform;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Captures a still frame from a playing <see cref="MediaPlayer"/> to a PNG via
/// libVLC's <c>TakeSnapshot</c>, honoring the snapshot-destination setting:
/// clipboard (via <see cref="ImageClipboard"/>) or the configured folder
/// (falling back to the OS Pictures folder). libVLC writes the file
/// asynchronously, so capture awaits its appearance before proceeding.
/// </summary>
public static class SnapshotService
{
    public sealed record Result(bool Ok, string? Path, string Message);

    public static async Task<Result> CaptureAsync(MediaPlayer? player, string cameraName)
    {
        if (player == null)
            return new Result(false, null, Localization.Loc.Get("Video is unavailable."));
        if (!player.IsPlaying)
            return new Result(false, null, Localization.Loc.Get("Camera isn't playing yet."));

        var toClipboard = AppSettings.Shared.SnapshotDest == AppSettings.SnapshotDestination.Clipboard;
        var dir = toClipboard ? System.IO.Path.GetTempPath() : ResolveFolder();
        try { Directory.CreateDirectory(dir); }
        catch (Exception ex) { return new Result(false, null, $"Can't create folder: {ex.Message}"); }

        var path = System.IO.Path.Combine(dir, SnapshotNaming.FileName(cameraName, DateTime.Now));
        try
        {
            // num=0 (first video output), width=height=0 → native resolution.
            if (!player.TakeSnapshot(0, path, 0, 0))
                return new Result(false, null, Localization.Loc.Get("Snapshot failed."));
            if (!await WaitForFileAsync(path))
                return new Result(false, null, Localization.Loc.Get("Snapshot failed."));

            if (!toClipboard)
                return new Result(true, path, $"{Localization.Loc.Get("Saved")} {System.IO.Path.GetFileName(path)}");

            var copied = ImageClipboard.TrySetPng(path);
            try { File.Delete(path); } catch { /* temp file; best effort */ }
            return copied
                ? new Result(true, null, Localization.Loc.Get("Snapshot copied to clipboard"))
                : new Result(false, null, Localization.Loc.Get("Clipboard is unavailable."));
        }
        catch (Exception ex)
        {
            Log.Line($"[Snapshot] failed: {ex.Message}");
            return new Result(false, null, ex.Message);
        }
    }

    /// <summary>libVLC writes the snapshot off-thread; poll briefly until it lands.</summary>
    private static async Task<bool> WaitForFileAsync(string path)
    {
        for (var i = 0; i < 60; i++) // up to ~3s
        {
            try
            {
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 0)
                {
                    // Writable exclusively → libVLC has finished writing.
                    using var _ = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.None);
                    return true;
                }
            }
            catch (IOException) { /* still being written */ }
            await Task.Delay(50);
        }
        return false;
    }

    private static string ResolveFolder()
    {
        var configured = AppSettings.Shared.SnapshotFolder;
        if (!string.IsNullOrWhiteSpace(configured)) return configured!;
        var pics = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return System.IO.Path.Combine(string.IsNullOrEmpty(pics) ? AppPaths.ConfigDirectory : pics, "QuickProtect");
    }
}
