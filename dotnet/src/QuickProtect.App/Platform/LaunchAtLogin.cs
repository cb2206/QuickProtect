using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

public static class LaunchAtLoginFactory
{
    public static ILaunchAtLogin Create()
    {
        if (OperatingSystem.IsWindows()) return new WindowsLaunchAtLogin();
        if (OperatingSystem.IsLinux()) return new LinuxLaunchAtLogin();
        return new NoopLaunchAtLogin();
    }
}

/// <summary>
/// Windows "start at login" via the per-user Run registry key.
///
/// In an MSIX package that key is the wrong mechanism: the write is
/// virtualised into the package's private registry hive, so the OS never reads
/// it back and the app would simply not start. Packaged builds therefore
/// declare a <c>windows.startupTask</c> extension in the manifest and let
/// Windows own the switch (Settings → Apps → Startup); this class reports that
/// via <see cref="IsManagedByOS"/> instead of writing a key that does nothing.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsLaunchAtLogin : ILaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "QuickProtect";

    public bool IsManagedByOS { get; } = AppDistribution.IsWindowsPackaged;

    public bool IsEnabled
    {
        get
        {
            // The manifest's startup task is opt-in and its state lives with
            // the OS; without WinRT there is nothing truthful to report.
            if (IsManagedByOS) return false;
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public void SetEnabled(bool enabled)
    {
        if (IsManagedByOS) return;
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
        if (key == null) return;
        if (enabled)
        {
            var exe = Environment.ProcessPath ?? System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
            if (exe != null) key.SetValue(ValueName, $"\"{exe}\"");
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}

/// <summary>Linux "start at login" via an XDG autostart .desktop entry.</summary>
[SupportedOSPlatform("linux")]
public sealed class LinuxLaunchAtLogin : ILaunchAtLogin
{
    private static string AutostartFile
    {
        get
        {
            var configHome = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            return Path.Combine(configHome, "autostart", "quickprotect.desktop");
        }
    }

    public bool IsEnabled => File.Exists(AutostartFile);

    public void SetEnabled(bool enabled)
    {
        var file = AutostartFile;
        if (enabled)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var exe = Environment.ProcessPath ?? "quickprotect";
            File.WriteAllText(file,
                "[Desktop Entry]\n" +
                "Type=Application\n" +
                "Name=QuickProtect\n" +
                $"Exec={QuoteExec(exe)}\n" +
                "X-GNOME-Autostart-enabled=true\n");
        }
        else if (File.Exists(file))
        {
            File.Delete(file);
        }
    }

    /// <summary>
    /// Quotes a path for a desktop-entry <c>Exec=</c> line (spaces in the
    /// install path would otherwise split the command). Per the spec, the
    /// reserved characters inside double quotes are escaped with a backslash.
    /// </summary>
    internal static string QuoteExec(string path)
    {
        var escaped = path.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("`", "\\`").Replace("$", "\\$");
        return "\"" + escaped + "\"";
    }
}
