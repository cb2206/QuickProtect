using System.Runtime.Versioning;
using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// The decision <see cref="LinuxDisplayScaling"/> makes at startup: whether the
/// desktop's GDK_SCALE has to be translated into Avalonia's own scaling
/// variable, and into what. The rule only fires for a Wayland session (where
/// the app is an unscaled XWayland client) and never overrides a scale the
/// session already states.
///
/// Pure decision logic over a supplied environment, so it runs on every CI leg
/// rather than only the Linux one.
/// </summary>
[SupportedOSPlatform("linux")]
public class DisplayScalingTests
{
    /// <summary>A HiDPI Wayland desktop: GDK_SCALE is the only signal there is.</summary>
    [Fact]
    public void WaylandSessionAdoptsTheDesktopScale()
    {
        Assert.Equal(2.0, Resolve(("WAYLAND_DISPLAY", "wayland-1"), ("GDK_SCALE", "2")));
    }

    /// <summary>
    /// GDK_SCALE is whole-number only, so fractional desktops pair it with a
    /// GDK_DPI_SCALE trim. 2 × 0.8 is a 1.6 monitor.
    /// </summary>
    [Fact]
    public void FractionalTrimMultipliesIntoTheScale()
    {
        Assert.Equal(1.6, Resolve(("WAYLAND_DISPLAY", "wayland-1"), ("GDK_SCALE", "2"), ("GDK_DPI_SCALE", "0.8")));
    }

    /// <summary>
    /// An X11 session states its DPI through Xft.dpi, which Avalonia reads
    /// itself; scaling on top of that would double-count.
    /// </summary>
    [Fact]
    public void X11SessionIsLeftToAvalonia()
    {
        Assert.Null(Resolve(("GDK_SCALE", "2")));
    }

    /// <summary>Every variable Avalonia reads for itself wins over the guess.</summary>
    [Theory]
    [InlineData("AVALONIA_GLOBAL_SCALE_FACTOR")]
    [InlineData("AVALONIA_SCREEN_SCALE_FACTORS")]
    [InlineData("QT_SCALE_FACTOR")]
    [InlineData("QT_SCREEN_SCALE_FACTORS")]
    public void ExplicitScalingWins(string variable)
    {
        Assert.Null(Resolve(("WAYLAND_DISPLAY", "wayland-1"), ("GDK_SCALE", "2"), (variable, "3")));
    }

    /// <summary>
    /// Nothing to correct (1x is Avalonia's own behaviour), nothing to read, or
    /// a value no display could mean: leave the variable unset either way.
    /// </summary>
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("1")]
    [InlineData("0")]
    [InlineData("-2")]
    [InlineData("42")]
    [InlineData("large")]
    public void NoUsableScaleChangesNothing(string? gdkScale)
    {
        Assert.Null(Resolve(("WAYLAND_DISPLAY", "wayland-1"), ("GDK_SCALE", gdkScale)));
    }

    /// <summary>A nonsense trim is ignored rather than allowed to shrink the UI.</summary>
    [Fact]
    public void UnusableTrimFallsBackToTheWholeScale()
    {
        Assert.Equal(2.0, Resolve(("WAYLAND_DISPLAY", "wayland-1"), ("GDK_SCALE", "2"), ("GDK_DPI_SCALE", "0")));
    }

    private static double? Resolve(params (string Name, string? Value)[] environment)
    {
        var values = environment.ToDictionary(entry => entry.Name, entry => entry.Value, StringComparer.Ordinal);
        return LinuxDisplayScaling.Resolve(name => values.GetValueOrDefault(name));
    }
}
