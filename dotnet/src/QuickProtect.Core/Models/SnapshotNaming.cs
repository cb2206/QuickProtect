using System.Text;

namespace QuickProtect.Core.Models;

/// <summary>
/// Builds a safe, timestamped snapshot filename. Pure (timestamp passed in) so
/// it is unit-testable and deterministic.
/// </summary>
public static class SnapshotNaming
{
    /// <summary>e.g. <c>QuickProtect_Front-Door_2026-06-25_14-30-05.png</c>.</summary>
    public static string FileName(string cameraName, DateTime timestamp)
    {
        var safe = Sanitize(cameraName);
        var stamp = timestamp.ToString("yyyy-MM-dd_HH-mm-ss");
        return $"QuickProtect_{safe}_{stamp}.png";
    }

    /// <summary>Reduce a camera name to filename-safe characters.</summary>
    private static string Sanitize(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var ch in name.Trim())
            sb.Append(char.IsLetterOrDigit(ch) ? ch : (ch is ' ' or '-' or '_' ? '-' : '_'));
        var result = sb.ToString().Trim('-', '_');
        return result.Length == 0 ? "Camera" : result;
    }
}
