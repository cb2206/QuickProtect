using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>The native Wayland backend is strictly opt-in (issue #4 spike).</summary>
public class NativeWaylandTests
{
    private static Func<string, string?> Env(params (string Key, string Value)[] vars)
        => key => vars.FirstOrDefault(v => v.Key == key).Value;

    [Fact]
    public void Needs_the_opt_in_and_a_Wayland_session_on_Linux()
    {
        var both = Env(("QUICKPROTECT_WAYLAND", "1"), ("WAYLAND_DISPLAY", "wayland-1"));
        Assert.Equal(OperatingSystem.IsLinux(), NativeWayland.IsRequestedBy(both));
    }

    [Theory]
    [InlineData(null, "wayland-1")]
    [InlineData("0", "wayland-1")]
    [InlineData("true", "wayland-1")]
    [InlineData("1", null)]
    [InlineData("1", "")]
    public void Stays_on_X11_otherwise(string? optIn, string? display)
    {
        var vars = new List<(string, string)>();
        if (optIn != null) vars.Add(("QUICKPROTECT_WAYLAND", optIn));
        if (display != null) vars.Add(("WAYLAND_DISPLAY", display));
        Assert.False(NativeWayland.IsRequestedBy(Env([.. vars])));
    }
}
