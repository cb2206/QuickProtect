namespace QuickProtect.Core.Services;

/// <summary>
/// Per-user storage locations, resolved per OS. On Windows this is
/// <c>%APPDATA%\QuickProtect</c>; on Linux <c>$XDG_CONFIG_HOME/QuickProtect</c>
/// (falling back to <c>~/.config/QuickProtect</c>). The directory holds the
/// secret store's file fallback, so on Unix it is created owner-only (0700).
/// </summary>
public static class AppPaths
{
    public const string AppFolderName = "QuickProtect";

    public static string ConfigDirectory
    {
        get
        {
            string root;
            if (OperatingSystem.IsWindows())
            {
                root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            }
            else
            {
                root = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME")
                       ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            }
            var dir = Path.Combine(root, AppFolderName);
            if (OperatingSystem.IsWindows())
            {
                Directory.CreateDirectory(dir);
            }
            else
            {
                const UnixFileMode ownerOnly = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir, ownerOnly);
                else
                {
                    try { File.SetUnixFileMode(dir, ownerOnly); } catch { /* best effort */ }
                }
            }
            return dir;
        }
    }
}
