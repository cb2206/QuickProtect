using Avalonia;
using Avalonia.Controls;
using QuickProtect.App.Views;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// The focus header never lets the title overlap the back button or the
/// actions: it drops to compact (icon-only) labels first, then narrows the title.
/// </summary>
public class FocusHeaderPanelTests
{
    private static (FocusHeaderPanel Panel, Border Left, Border Title, Border Right) Header(
        double left, double title, double right)
    {
        var l = new Border { Width = left, Height = 30 };
        var t = new Border { Width = double.NaN, Height = 20, Child = new Border { Width = title, Height = 20 } };
        var r = new Border { Width = right, Height = 30 };
        var panel = new FocusHeaderPanel();
        panel.Children.Add(l);
        panel.Children.Add(t);
        panel.Children.Add(r);
        return (panel, l, t, r);
    }

    private static void Layout(FocusHeaderPanel panel, double width)
    {
        panel.Measure(new Size(width, 40));
        panel.Arrange(new Rect(0, 0, width, 40));
    }

    [Fact]
    public void Title_is_centered_on_the_bar_when_everything_fits() => UiThread.Run(() =>
    {
        var (panel, _, title, _) = Header(left: 80, title: 120, right: 300);
        Layout(panel, 800);

        Assert.False(panel.IsCompact);
        Assert.Equal((800 - 120) / 2.0, title.Bounds.X, precision: 3);
        Assert.Equal(120, title.Bounds.Width, precision: 3);
    });

    [Fact]
    public void Title_centers_in_the_gap_when_it_cannot_center_on_the_bar() => UiThread.Run(() =>
    {
        // Wide actions: centered on the 800 bar the title would span 340-460,
        // past the actions' start at 400. The gap (80-400) centers it at 240.
        var (panel, left, title, right) = Header(left: 80, title: 120, right: 400);
        Layout(panel, 800);

        Assert.False(panel.IsCompact);
        var gapCenter = (left.Bounds.Right + right.Bounds.X) / 2;
        Assert.Equal(gapCenter, title.Bounds.Center.X, precision: 3);
    });

    [Fact]
    public void Labels_collapse_before_the_title_is_squeezed_and_return_when_there_is_room() => UiThread.Run(() =>
    {
        var (panel, _, _, _) = Header(left: 80, title: 120, right: 500);
        Layout(panel, 650); // 80 + 500 + 120 = 700 > 650
        Assert.True(panel.IsCompact);

        Layout(panel, 720);
        Assert.False(panel.IsCompact);
    });

    // Widths from just above the two side groups (440, which fixed-size test
    // children can't shrink below; the app's compact icons are ~190) upward.
    [Theory]
    [InlineData(450)]
    [InlineData(460)]
    [InlineData(560)]
    [InlineData(740)]
    [InlineData(1200)]
    public void Title_never_overlaps_the_sides(double width) => UiThread.Run(() =>
    {
        var (panel, left, title, right) = Header(left: 80, title: 260, right: 360);
        Layout(panel, width);

        Assert.True(title.Bounds.X >= left.Bounds.Right - 0.001, $"title starts at {title.Bounds.X}, back ends at {left.Bounds.Right}");
        Assert.True(title.Bounds.Right <= right.Bounds.X + 0.001, $"title ends at {title.Bounds.Right}, actions start at {right.Bounds.X}");
        Assert.True(title.Bounds.Width <= 260 + 0.001);
    });
}
