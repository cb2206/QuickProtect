namespace QuickProtect.Core.Services;

/// <summary>
/// Platform hook for "start at login". Windows uses a Run-key registry entry;
/// Linux writes an XDG autostart <c>.desktop</c> file. The app layer supplies the
/// implementation so Core stays platform-free (mirrors macOS <c>SMAppService</c> use).
/// </summary>
public interface ILaunchAtLogin
{
    bool IsEnabled { get; }
    void SetEnabled(bool enabled);
}

/// <summary>No-op default used until the platform layer installs a real one.</summary>
public sealed class NoopLaunchAtLogin : ILaunchAtLogin
{
    public bool IsEnabled { get; private set; }
    public void SetEnabled(bool enabled) => IsEnabled = enabled;
}
