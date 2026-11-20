namespace QuickProtect.App.Platform;

/// <summary>
/// Opt-in native Wayland backend (issue #4, spike). By default the app stays
/// an X11 client through XWayland, which is what every Linux release so far
/// has shipped and what <see cref="Hyprland"/>'s overlay mode and
/// <see cref="LinuxDisplayScaling"/> are built around.
///
/// With <c>QUICKPROTECT_WAYLAND=1</c> in a Wayland session the app asks for
/// Avalonia 12's experimental <c>Avalonia.Wayland</c> backend instead, through
/// <c>UseWaylandWithFallback</c>: when no usable compositor answers it falls
/// back to the X11 backend <c>UsePlatformDetect</c> configured, so the switch
/// can't keep the app from starting. Things to check with it on are listed
/// in the issue: tray icon, pinned-window placement (Wayland clients can't
/// position themselves), the portal hotkey, fractional scaling, and the video
/// surface's throughput.
/// </summary>
internal static class NativeWayland
{
    public const string OptInVariable = "QUICKPROTECT_WAYLAND";

    /// <summary>
    /// Matches the installed <c>quickprotect.desktop</c>, so compositors pair
    /// the windows with the desktop entry (icon, grouping, portal app id).
    /// </summary>
    public const string AppId = "quickprotect";

    /// <summary>The user opted in and the session is a Wayland one.</summary>
    public static bool IsRequested => IsRequestedBy(Environment.GetEnvironmentVariable);

    internal static bool IsRequestedBy(Func<string, string?> env)
        => OperatingSystem.IsLinux()
           && env(OptInVariable) == "1"
           && !string.IsNullOrEmpty(env("WAYLAND_DISPLAY"));
}
