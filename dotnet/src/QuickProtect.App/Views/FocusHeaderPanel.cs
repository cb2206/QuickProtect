using Avalonia;
using Avalonia.Controls;

namespace QuickProtect.App.Views;

/// <summary>
/// The focus view's top bar: back button (child 0), camera title (child 1),
/// action buttons (child 2). When the full labels don't fit (long translations
/// such as German, or a narrow panel) the panel sets <c>:compact</c>, which
/// the window's styles use to drop the labels to icons with tooltips. Only if
/// even that is too wide does the title get less than its natural width (and
/// trims). The title is centered on the whole bar like the macOS header, and
/// slides aside rather than overlapping the buttons.
/// </summary>
public sealed class FocusHeaderPanel : Panel
{
    // Width of the side groups with labels, remembered while compact so the
    // panel knows when there is room to show them again.
    private double _fullSidesWidth;

    public bool IsCompact => PseudoClasses.Contains(":compact");

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Children.Count < 3) return default;
        Control left = Children[0], center = Children[1], right = Children[2];
        var infinite = new Size(double.PositiveInfinity, availableSize.Height);

        center.Measure(infinite);
        var titleWidth = center.DesiredSize.Width;
        var width = availableSize.Width;

        if (double.IsInfinity(width))
        {
            SetCompact(false);
        }
        else
        {
            if (IsCompact && _fullSidesWidth + titleWidth <= width) SetCompact(false);
            if (!IsCompact)
            {
                left.Measure(infinite);
                right.Measure(infinite);
                _fullSidesWidth = left.DesiredSize.Width + right.DesiredSize.Width;
                if (_fullSidesWidth + titleWidth > width) SetCompact(true);
            }
        }

        left.Measure(infinite);
        right.Measure(infinite);
        var sides = left.DesiredSize.Width + right.DesiredSize.Width;
        var titleRoom = double.IsInfinity(width) ? double.PositiveInfinity : Math.Max(0, width - sides);
        center.Measure(new Size(titleRoom, availableSize.Height));

        var height = Math.Max(left.DesiredSize.Height, Math.Max(center.DesiredSize.Height, right.DesiredSize.Height));
        var desiredWidth = double.IsInfinity(width) ? sides + center.DesiredSize.Width : width;
        return new Size(desiredWidth, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        if (Children.Count < 3) return finalSize;
        Control left = Children[0], center = Children[1], right = Children[2];
        var h = finalSize.Height;
        var leftWidth = left.DesiredSize.Width;
        var rightWidth = right.DesiredSize.Width;

        left.Arrange(new Rect(0, 0, leftWidth, h));
        right.Arrange(new Rect(finalSize.Width - rightWidth, 0, rightWidth, h));

        // Centered on the bar when the gap allows it, else centered in the gap.
        var gapStart = leftWidth;
        var gapWidth = Math.Max(0, finalSize.Width - leftWidth - rightWidth);
        var titleWidth = Math.Min(center.DesiredSize.Width, gapWidth);
        var onBar = (finalSize.Width - titleWidth) / 2;
        var x = onBar >= gapStart && onBar + titleWidth <= gapStart + gapWidth
            ? onBar
            : gapStart + (gapWidth - titleWidth) / 2;
        center.Arrange(new Rect(x, 0, titleWidth, h));
        return finalSize;
    }

    private void SetCompact(bool compact)
    {
        if (IsCompact == compact) return;
        // Applied synchronously by the styles, so the re-measure below sees it.
        PseudoClasses.Set(":compact", compact);
    }
}
