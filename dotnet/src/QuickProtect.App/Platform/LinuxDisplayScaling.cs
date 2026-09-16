using System.Globalization;
using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Hands Avalonia the desktop's display scale on Wayland sessions, so the UI
/// is the size the compositor's HiDPI setting asks for.
///
/// Avalonia 11 has no Wayland backend, so on Hyprland, sway and friends the
/// app is an X11 client running through XWayland. Those compositors hand
/// XWayland an unscaled surface (Hyprland's <c>xwayland:force_zero_scaling</c>,
/// on by default in Omarchy) and tell toolkits to scale themselves through
/// <c>GDK_SCALE</c> — which is how every GTK and Electron app on such a desktop
/// follows an ad-hoc scale change. Avalonia never reads that variable: its X11
/// backend looks at <c>AVALONIA_GLOBAL_SCALE_FACTOR</c>,
/// <c>AVALONIA_SCREEN_SCALE_FACTORS</c>, the <c>QT_*</c> equivalents and
/// <c>Xft.dpi</c>, none of which a Wayland session sets. With no signal it
/// renders at 1×, so on a 2× display every control comes out half-size.
///
/// Translating GDK_SCALE into Avalonia's own variable before the platform
/// initializes closes that gap. GTK only honors whole-number GDK_SCALE values,
/// so a fractional monitor scale (1.25, 1.6) reaches us rounded — exactly the
/// size those GTK neighbours render at. Anyone who wants the fractional value
/// can set <c>AVALONIA_GLOBAL_SCALE_FACTOR</c> themselves; an explicit setting
/// always wins.
/// </summary>
[SupportedOSPlatform("linux")]
internal static class LinuxDisplayScaling
{
    private const string AvaloniaGlobalScale = "AVALONIA_GLOBAL_SCALE_FACTOR";

    /// <summary>
    /// The scaling inputs Avalonia's X11 backend reads on its own. Any of them
    /// being set means the session already has an answer, and a guess of ours
    /// would only override it.
    /// </summary>
    private static readonly string[] ScaleVariablesAvaloniaReads =
    {
        AvaloniaGlobalScale, "AVALONIA_SCREEN_SCALE_FACTORS", "QT_SCALE_FACTOR", "QT_SCREEN_SCALE_FACTORS",
    };

    /// <summary>
    /// Sets <c>AVALONIA_GLOBAL_SCALE_FACTOR</c> from the desktop's own scaling
    /// hint when nothing else has. Must run before the Avalonia platform
    /// initializes — the X11 backend reads the variable once, at startup.
    /// </summary>
    internal static void Apply()
    {
        if (Resolve(Environment.GetEnvironmentVariable) is not { } factor) return;

        Environment.SetEnvironmentVariable(AvaloniaGlobalScale, factor.ToString(CultureInfo.InvariantCulture));
        Log.Line($"[Display] scaling the UI by {factor}x to match the desktop (GDK_SCALE)");
    }

    /// <summary>
    /// The scale factor to apply, or <c>null</c> to leave Avalonia's own
    /// detection alone. Takes the environment as a function so the decision is
    /// testable without touching the process's own variables.
    /// </summary>
    internal static double? Resolve(Func<string, string?> env)
    {
        // A real X11 session reports DPI through Xft.dpi, which Avalonia
        // already honors; only the XWayland case needs the translation.
        if (string.IsNullOrEmpty(env("WAYLAND_DISPLAY"))) return null;

        foreach (var name in ScaleVariablesAvaloniaReads)
            if (!string.IsNullOrEmpty(env(name)))
                return null;

        if (ParsePositive(env("GDK_SCALE")) is not { } gdkScale) return null;

        // GDK_DPI_SCALE is the fractional trim some setups pair with an integer
        // GDK_SCALE (2 × 0.8 for a 1.6 monitor). Absent, it is simply 1.
        var dpiScale = ParsePositive(env("GDK_DPI_SCALE")) ?? 1.0;

        var factor = gdkScale * dpiScale;
        // 1x is what Avalonia does anyway, and a wild value is a broken
        // environment rather than an instruction worth following.
        return factor is > 1.0 and <= 16.0 ? factor : null;
    }

    private static double? ParsePositive(string? value)
        => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            && double.IsFinite(parsed) && parsed > 0
            ? parsed
            : null;
}
