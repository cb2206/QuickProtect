using Avalonia;
using Avalonia.Controls;
using QuickProtect.App.Views;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// The frame <see cref="ResizeGrips"/> computes when it runs a resize drag
/// itself (Hyprland, which ignores an XWayland client's own resize request):
/// the dragged edge follows the pointer, the opposite edge stays put, and the
/// window's size limits hold.
/// </summary>
public class ResizeGripsTests
{
    private static readonly PixelPoint Start = new(1000, 600);
    private static readonly Size StartSize = new(760, 520);
    private static readonly Size Min = new(400, 300);
    private static readonly Size Max = new(double.PositiveInfinity, double.PositiveInfinity);

    private static (PixelPoint Position, Size Size) Drag(WindowEdge edge, double dx, double dy, double scaling = 2)
        => ResizeGrips.Resized(Start, StartSize, edge, new Vector(dx, dy), Min, Max, scaling);

    [Fact]
    public void SouthEastGrowsWithoutMoving()
    {
        Assert.Equal((Start, new Size(860, 570)), Drag(WindowEdge.SouthEast, 100, 50));
    }

    /// <summary>The origin moves in screen pixels (DIPs × scaling), keeping the right/bottom edge fixed.</summary>
    [Fact]
    public void NorthWestMovesTheOriginWithTheEdge()
    {
        Assert.Equal((new PixelPoint(800, 500), new Size(860, 570)), Drag(WindowEdge.NorthWest, -100, -50));
    }

    [Fact]
    public void SideEdgesOnlyChangeTheirOwnAxis()
    {
        Assert.Equal((Start, new Size(760, 580)), Drag(WindowEdge.South, 40, 60));
        Assert.Equal((new PixelPoint(1080, 600), new Size(720, 520)), Drag(WindowEdge.West, 40, 60));
    }

    /// <summary>
    /// Shrinking past the minimum stops at it, and the west edge stops with it
    /// instead of pushing the window sideways.
    /// </summary>
    [Fact]
    public void MinimumSizeHoldsAndPinsTheOppositeEdge()
    {
        var (position, size) = Drag(WindowEdge.West, 500, 0);
        Assert.Equal(new Size(400, 520), size);
        Assert.Equal(new PixelPoint(1000 + (760 - 400) * 2, 600), position);
    }
}
