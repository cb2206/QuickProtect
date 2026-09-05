using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using QuickProtect.App.Platform;
using QuickProtect.App.ViewModels;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Services;

/// <summary>
/// Captures a still from a tile's video engine: the latest decoded frame is
/// encoded to PNG in-process (native resolution, no temp-file round-trip) and
/// saved to the configured folder or placed on the clipboard.
/// </summary>
public static class SnapshotService
{
    public sealed record Result(bool Ok, string? Path, string Message);

    public static Task<Result> CaptureAsync(CameraTileViewModel tile) => Task.Run(() => Capture(tile));

    private static Result Capture(CameraTileViewModel tile)
    {
        if (tile.Client is not { } client)
            return new Result(false, null, Localization.Loc.Get("Video is unavailable."));

        byte[]? buffer = null;
        long seq = -1;
        if (!client.TryCopyFrame(ref buffer, ref seq, out var w, out var h, out var stride) || buffer == null)
            return new Result(false, null, Localization.Loc.Get("Camera isn't playing yet."));

        using var bmp = new WriteableBitmap(new PixelSize(w, h), new Vector(96, 96),
            PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using (var fb = bmp.Lock())
        {
            if (fb.RowBytes == stride)
            {
                Marshal.Copy(buffer, 0, fb.Address, stride * h);
            }
            else
            {
                for (var row = 0; row < h; row++)
                    Marshal.Copy(buffer, row * stride, fb.Address + row * fb.RowBytes, stride);
            }
        }

        try
        {
            if (AppSettings.Shared.SnapshotDest == AppSettings.SnapshotDestination.Clipboard)
            {
                var tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                    SnapshotNaming.FileName(tile.Name, DateTime.Now));
                bmp.Save(tmp);
                var copied = ImageClipboard.TrySetPng(tmp);
                try { File.Delete(tmp); } catch { /* temp file; best effort */ }
                return copied
                    ? new Result(true, null, Localization.Loc.Get("Snapshot copied to clipboard"))
                    : new Result(false, null, Localization.Loc.Get("Clipboard is unavailable."));
            }

            var dir = ResolveFolder();
            Directory.CreateDirectory(dir);
            var path = System.IO.Path.Combine(dir, SnapshotNaming.FileName(tile.Name, DateTime.Now));
            bmp.Save(path);
            return new Result(true, path, $"{Localization.Loc.Get("Saved")} {System.IO.Path.GetFileName(path)}");
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
        return System.IO.Path.Combine(string.IsNullOrEmpty(pics) ? AppPaths.ConfigDirectory : pics, "QuickProtect");
    }
}
