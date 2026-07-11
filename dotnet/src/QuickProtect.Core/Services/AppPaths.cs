namespace QuickProtect.Core.Services;

/// <summary>
/// Per-user storage locations, resolved per OS. On Windows this is
/// <c>%APPDATA%\QuickProtect</c>; on Linux <c>$XDG_CONFIG_HOME/QuickProtect</c>
/// (falling back to <c>~/.config/QuickProtect</c>).
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
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
}
