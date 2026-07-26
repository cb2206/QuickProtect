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

    /// <summary>
    /// True when the OS owns this setting and the app cannot toggle it — an
    /// MSIX package declares its startup task in the manifest, and Windows
    /// exposes the switch under Settings → Apps → Startup instead. The UI
    /// shows a pointer there rather than a toggle that would do nothing.
    /// </summary>
    bool IsManagedByOS => false;
}

/// <summary>No-op default used until the platform layer installs a real one.</summary>
public sealed class NoopLaunchAtLogin : ILaunchAtLogin
{
    public bool IsEnabled { get; private set; }
    public void SetEnabled(bool enabled) => IsEnabled = enabled;
}
