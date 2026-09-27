using Avalonia;
using QuickProtect.App.Views;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Restoring the overlay panel's saved position (Hyprland): it comes back where
/// the user left it, is pulled back onto its screen if that screen changed, and
/// is dropped (the panel gets centered) when its monitor is gone.
/// </summary>
public class PanelPositionTests
{
    private static readonly PixelSize Panel = new(1400, 900);
    private static readonly PixelRect Laptop = new(0, 0, 3024, 1964);
    private static readonly PixelRect External = new(3024, 0, 2560, 1440);

    [Fact]
    public void PositionOnAScreenIsKept()
    {
        Assert.Equal(new PixelPoint(200, 300),
            MainWindow.RestorablePosition(new PixelPoint(200, 300), Panel, [Laptop]));
    }

    [Fact]
    public void PanelHangingOffItsScreenIsPulledBackOn()
    {
        // Center (2700, 1000) is on the laptop screen; the right edge (3400) overhangs.
        Assert.Equal(new PixelPoint(3024 - 1400, 550),
            MainWindow.RestorablePosition(new PixelPoint(2000, 550), Panel, [Laptop]));
    }

    [Fact]
    public void PositionOnASecondMonitorIsKeptWhileItIsConnected()
    {
        Assert.Equal(new PixelPoint(3300, 200),
            MainWindow.RestorablePosition(new PixelPoint(3300, 200), Panel, [Laptop, External]));
    }

    [Fact]
    public void PositionOnADisconnectedMonitorIsDropped()
    {
        Assert.Null(MainWindow.RestorablePosition(new PixelPoint(3300, 200), Panel, [Laptop]));
    }
}
