using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// The parsing behind <see cref="Hyprland"/>'s overlay mode: the IPC replies
/// (<c>j/monitors</c>, <c>j/clients</c>) and event-socket lines it acts on.
/// Pure string handling, so it runs on every CI leg without a compositor.
/// </summary>
public class HyprlandTests
{
    [Fact]
    public void EventLineSplitsIntoNameAndData()
    {
        Assert.True(Hyprland.TryParseEvent("workspacev2>>3,3", out var name, out var data));
        Assert.Equal("workspacev2", name);
        Assert.Equal("3,3", data);
    }

    /// <summary>Titles may themselves contain "&gt;&gt;"; only the first one separates.</summary>
    [Fact]
    public void EventDataKeepsLaterSeparators()
    {
        Assert.True(Hyprland.TryParseEvent("activewindow>>foot,a >> b", out var name, out var data));
        Assert.Equal("activewindow", name);
        Assert.Equal("foot,a >> b", data);
    }

    [Theory]
    [InlineData("")]
    [InlineData("garbage")]
    [InlineData(">>no-name")]
    public void MalformedEventLinesAreRejected(string line)
    {
        Assert.False(Hyprland.TryParseEvent(line, out _, out _));
    }

    [Fact]
    public void FocusedMonitorIsPickedWithItsReservedStrip()
    {
        const string json = """
            [
              {"name":"HDMI-A-1","width":2560,"height":1440,"scale":1.0,"reserved":[0,0,0,0],"focused":false},
              {"name":"eDP-1","width":3024,"height":1964,"scale":2.0,"reserved":[0,32,0,0],"focused":true}
            ]
            """;
        var monitor = Hyprland.ParseFocusedMonitor(json);
        Assert.Equal(new Hyprland.Monitor("eDP-1", 3024, 1964, 2.0, 0, 32, 0, 0), monitor);
    }

    [Fact]
    public void NoFocusedMonitorGivesNull()
    {
        Assert.Null(Hyprland.ParseFocusedMonitor("""[{"name":"eDP-1","width":1,"height":1,"scale":1,"focused":false}]"""));
    }

    /// <summary>
    /// Pinned camera windows are found by this process's pid and their title,
    /// never another app's window that happens to share the camera's name.
    /// </summary>
    [Fact]
    public void ClientMatchesOnPidAndTitle()
    {
        const string json = """
            [
              {"address":"0xaaa","pid":10,"title":"Front Door","pinned":false},
              {"address":"0xbbb","pid":42,"title":"QuickProtect","pinned":false},
              {"address":"0xccc","pid":42,"title":"Front Door","pinned":true}
            ]
            """;
        Assert.Equal(new Hyprland.Client("0xccc", true), Hyprland.FindClient(json, 42, "Front Door"));
        Assert.Null(Hyprland.FindClient(json, 42, "Garage"));
    }
}
