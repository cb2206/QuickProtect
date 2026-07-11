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

/// <summary>Windows "start at login" via the per-user Run registry key.</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsLaunchAtLogin : ILaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "QuickProtect";

    public bool IsEnabled
    {
        get
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public void SetEnabled(bool enabled)
    {
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
                $"Exec={exe}\n" +
                "X-GNOME-Autostart-enabled=true\n");
        }
        else if (File.Exists(file))
        {
            File.Delete(file);
        }
    }
}
