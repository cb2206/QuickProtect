using System.Diagnostics;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>Opens a URL in the user's default browser, per OS.</summary>
public static class UrlOpener
{
    public static void Open(string url)
    {
        try
        {
            if (OperatingSystem.IsWindows())
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            else if (OperatingSystem.IsLinux())
                Process.Start("xdg-open", url);
            else if (OperatingSystem.IsMacOS())
                Process.Start("open", url);
        }
        catch (Exception ex)
        {
            Log.Line($"[UrlOpener] failed to open {url}: {ex.Message}");
        }
    }
}
