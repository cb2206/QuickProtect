using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia.Media.Imaging;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Puts a PNG image file on the system clipboard. Avalonia 11 has no portable
/// image-clipboard API, so each OS gets its own path:
///  • Windows — Win32 clipboard with CF_DIB (universally pasteable) plus the
///    registered "PNG" format (keeps transparency for apps that support it).
///  • Linux — shells out to wl-copy (Wayland) or xclip (X11), whichever exists.
///  • macOS — osascript writes the file to the clipboard as PNG.
/// Returns false when the platform has no working clipboard path.
/// </summary>
public static class ImageClipboard
{
    public static bool TrySetPng(string pngPath)
    {
        try
        {
            if (OperatingSystem.IsWindows()) return SetWindows(pngPath);
            if (OperatingSystem.IsLinux()) return SetLinux(pngPath);
            if (OperatingSystem.IsMacOS()) return SetMac(pngPath);
        }
        catch (Exception ex)
        {
            Log.Line($"[Clipboard] image copy failed: {ex.Message}");
        }
        return false;
    }

    // MARK: - Windows (Win32 clipboard, CF_DIB + registered PNG)

    private const uint CF_DIB = 8;
    private const uint GMEM_MOVEABLE = 0x0002;

    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint RegisterClipboardFormatW([MarshalAs(UnmanagedType.LPWStr)] string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr mem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalUnlock(IntPtr mem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalFree(IntPtr mem);

    private static bool SetWindows(string pngPath)
    {
        var pngBytes = File.ReadAllBytes(pngPath);
        var dib = PngToDib(pngPath);

        if (!OpenClipboard(IntPtr.Zero)) return false;
        try
        {
            if (!EmptyClipboard()) return false;
            var ok = PutBytes(CF_DIB, dib);
            var pngFormat = RegisterClipboardFormatW("PNG");
            if (pngFormat != 0) PutBytes(pngFormat, pngBytes);
            return ok;
        }
        finally { CloseClipboard(); }
    }

    private static bool PutBytes(uint format, byte[] bytes)
    {
        var h = GlobalAlloc(GMEM_MOVEABLE, (nuint)bytes.Length);
        if (h == IntPtr.Zero) return false;
        var p = GlobalLock(h);
        if (p == IntPtr.Zero) { GlobalFree(h); return false; }
        Marshal.Copy(bytes, 0, p, bytes.Length);
        GlobalUnlock(h);
        if (SetClipboardData(format, h) == IntPtr.Zero)
        {
            GlobalFree(h); // ownership only transfers on success
            return false;
        }
        return true;
    }

    /// <summary>Decode the PNG with Avalonia and repack as a 32bpp top-down CF_DIB.</summary>
    private static byte[] PngToDib(string pngPath)
    {
        using var bmp = new Bitmap(pngPath);
        var w = bmp.PixelSize.Width;
        var h = bmp.PixelSize.Height;
        var stride = w * 4;
        var pixels = new byte[stride * h];
        var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        try
        {
            bmp.CopyPixels(new Avalonia.PixelRect(0, 0, w, h), handle.AddrOfPinnedObject(), pixels.Length, stride);
        }
        finally { handle.Free(); }

        // BITMAPINFOHEADER (40 bytes), BI_RGB 32bpp. Bottom-up row order —
        // top-down (negative-height) DIBs are valid but GDI+/paste targets
        // commonly reject them on the clipboard.
        var dib = new byte[40 + pixels.Length];
        using var ms = new MemoryStream(dib);
        using var bw = new BinaryWriter(ms);
        bw.Write(40); bw.Write(w); bw.Write(h);
        bw.Write((ushort)1); bw.Write((ushort)32);
        bw.Write(0); bw.Write(pixels.Length);
        bw.Write(0); bw.Write(0); bw.Write(0); bw.Write(0);
        for (var row = h - 1; row >= 0; row--)
            bw.Write(pixels, row * stride, stride);
        return dib;
    }

    // MARK: - Linux (wl-copy / xclip)

    private static bool SetLinux(string pngPath)
    {
        // Wayland first, then X11. Both read the image from stdin.
        return Pipe("wl-copy", "--type image/png", pngPath)
            || Pipe("xclip", "-selection clipboard -t image/png", pngPath);
    }

    private static bool Pipe(string tool, string args, string file)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(tool, args)
            {
                RedirectStandardInput = true,
                UseShellExecute = false
            });
            if (p == null) return false;
            using (var fs = File.OpenRead(file)) fs.CopyTo(p.StandardInput.BaseStream);
            p.StandardInput.Close();
            return p.WaitForExit(5000) && p.ExitCode == 0;
        }
        catch { return false; } // tool not installed
    }

    // MARK: - macOS (osascript)

    private static bool SetMac(string pngPath)
    {
        var script = $"set the clipboard to (read (POSIX file \"{pngPath}\") as «class PNGf»)";
        try
        {
            using var p = Process.Start(new ProcessStartInfo("osascript", $"-e '{script}'") { UseShellExecute = false });
            return p != null && p.WaitForExit(5000) && p.ExitCode == 0;
        }
        catch { return false; }
    }
}
