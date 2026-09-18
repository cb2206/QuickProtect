using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Keeps QuickProtect's freedesktop entries usable when the app wasn't installed
/// by a package:
///
///  • The XDG desktop portal only accepts the app id "quickprotect" (see
///    <see cref="PortalGlobalHotkey"/>) when it resolves to an installed
///    quickprotect.desktop. Without one, a tarball run's global shortcut is filed
///    under whichever app launched it (the terminal, say). So when no entry is
///    installed anywhere, a hidden one is written to the user's applications
///    directory. A package's entry (the AUR package's /usr/share one) always
///    wins and is never shadowed.
///  • A "launch at login" autostart entry whose binary has moved away (a
///    re-extracted tarball, a rebuilt checkout) would silently do nothing at
///    login; it is repointed at the running binary. A working entry is left
///    alone, so a dev build never takes over a packaged install's autostart.
/// </summary>
[SupportedOSPlatform("linux")]
public static class LinuxDesktopEntries
{
    public const string FileName = "quickprotect.desktop";

    /// <summary>Marks entries this class wrote, so it never rewrites anyone else's.</summary>
    internal const string GeneratedMarker = "X-QuickProtect-Generated=true";

    public static void EnsureUsable()
    {
        var exe = Environment.ProcessPath;
        // `dotnet QuickProtect.dll` runs under the dotnet host: no stable binary to point at.
        if (exe == null || Path.GetFileNameWithoutExtension(exe) != "QuickProtect") return;
        try
        {
            EnsureApplicationEntry(exe);
            RepairAutostartEntry(exe);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Line($"[Desktop] could not update desktop entries: {e.Message}");
        }
    }

    private static void EnsureApplicationEntry(string exe)
    {
        var userFile = Path.Combine(DataHome(), "applications", FileName);
        var existing = File.Exists(userFile) ? File.ReadAllText(userFile) : null;
        var systemEntry = DataDirs().Any(d => File.Exists(Path.Combine(d, "applications", FileName)));
        if (!ApplicationEntryNeedsWrite(existing, systemEntry, File.Exists)) return;

        Directory.CreateDirectory(Path.GetDirectoryName(userFile)!);
        File.WriteAllText(userFile, GeneratedApplicationEntry(exe));
        Log.Line($"[Desktop] installed {userFile} so the desktop portal can identify QuickProtect");
    }

    private static void RepairAutostartEntry(string exe)
    {
        var file = LinuxLaunchAtLogin.AutostartFile;
        if (!File.Exists(file)) return;
        var content = File.ReadAllText(file);
        if (!ExecTargetIsMissing(content, File.Exists)) return;

        File.WriteAllText(file, ReplaceExec(content, exe));
        Log.Line($"[Desktop] launch at login pointed at a missing binary; now {exe}");
    }

    /// <summary>
    /// Whether the user-level application entry should be (re)written: never over
    /// an entry someone else wrote or when a system entry exists; otherwise when
    /// there is none, or ours points at a binary that is gone.
    /// </summary>
    internal static bool ApplicationEntryNeedsWrite(string? userEntry, bool systemEntryExists, Func<string, bool> fileExists)
    {
        if (userEntry == null) return !systemEntryExists;
        if (!userEntry.Contains(GeneratedMarker, StringComparison.Ordinal)) return false;
        return ExecTargetIsMissing(userEntry, fileExists);
    }

    internal static string GeneratedApplicationEntry(string exe) =>
        "[Desktop Entry]\n" +
        "Type=Application\n" +
        "Name=QuickProtect\n" +
        "Comment=Live viewer for UniFi Protect cameras\n" +
        $"Exec={LinuxLaunchAtLogin.QuoteExec(exe)}\n" +
        "Icon=quickprotect\n" +
        "Terminal=false\n" +
        // Written only so the desktop portal can resolve the app id — not a
        // launcher. Remove the file to undo; it is recreated while no packaged
        // entry exists.
        "NoDisplay=true\n" +
        GeneratedMarker + "\n";

    /// <summary>True when the entry's Exec names an absolute binary that doesn't exist.</summary>
    internal static bool ExecTargetIsMissing(string entry, Func<string, bool> fileExists)
        => ExecTarget(entry) is { } target && Path.IsPathRooted(target) && !fileExists(target);

    /// <summary>The program of the entry's <c>Exec=</c> line, unquoted per the desktop-entry spec.</summary>
    internal static string? ExecTarget(string entry)
    {
        var line = ExecLine(entry);
        if (line == null) return null;
        var value = line["Exec=".Length..].TrimStart();
        if (value.Length == 0) return null;
        if (value[0] != '"')
        {
            var space = value.IndexOf(' ');
            return space < 0 ? value : value[..space];
        }
        var sb = new System.Text.StringBuilder();
        for (var i = 1; i < value.Length; i++)
        {
            var c = value[i];
            if (c == '\\' && i + 1 < value.Length) { sb.Append(value[++i]); continue; }
            if (c == '"') return sb.ToString();
            sb.Append(c);
        }
        return null; // unterminated quote
    }

    internal static string ReplaceExec(string entry, string exe)
    {
        var line = ExecLine(entry);
        var exec = $"Exec={LinuxLaunchAtLogin.QuoteExec(exe)}";
        return line == null ? entry.TrimEnd('\n') + "\n" + exec + "\n" : entry.Replace(line, exec);
    }

    private static string? ExecLine(string entry)
        => entry.Split('\n').Select(l => l.TrimEnd('\r')).FirstOrDefault(l => l.StartsWith("Exec=", StringComparison.Ordinal));

    private static string DataHome()
        => Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } home
            ? home
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");

    private static IEnumerable<string> DataDirs()
        => (Environment.GetEnvironmentVariable("XDG_DATA_DIRS") is { Length: > 0 } dirs ? dirs : "/usr/local/share:/usr/share")
            .Split(':', StringSplitOptions.RemoveEmptyEntries);
}
