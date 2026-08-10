using Avalonia;
using Avalonia.Controls;

namespace QuickProtect.App.Views;

/// <summary>
/// Wrap panel that centers each row, matching the macOS grid's VStack-of-HStacks
/// (partial rows sit centered, not left-aligned). Children carry explicit sizes
/// (span-based tile widths), so measurement just packs them into rows in order.
/// A 1px tolerance keeps float rounding from spilling a full row's last tile.
/// </summary>
public sealed class CenteredWrapPanel : Panel
{
    private const double Tolerance = 1.0;

    protected override Size MeasureOverride(Size availableSize)
    {
        double rowWidth = 0, rowHeight = 0, totalHeight = 0, maxWidth = 0;
        foreach (var child in Children)
        {
            child.Measure(availableSize);
            var d = child.DesiredSize;
            if (d.Width <= 0) continue; // hidden (search-filtered) tiles take no slot
            if (rowWidth > 0 && rowWidth + d.Width > availableSize.Width + Tolerance)
            {
                totalHeight += rowHeight;
                maxWidth = Math.Max(maxWidth, rowWidth);
                rowWidth = 0;
                rowHeight = 0;
            }
            rowWidth += d.Width;
            rowHeight = Math.Max(rowHeight, d.Height);
        }
        totalHeight += rowHeight;
        maxWidth = Math.Max(maxWidth, rowWidth);
        return new Size(Math.Min(maxWidth, availableSize.Width), totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var row = new List<Avalonia.Controls.Control>();
        double rowWidth = 0, rowHeight = 0, y = 0;

        void ArrangeRow()
        {
            if (row.Count == 0) return;
            var x = Math.Max(0, (finalSize.Width - rowWidth) / 2);
            foreach (var child in row)
            {
                var d = child.DesiredSize;
                // Vertically centered within the row, like HStack's default alignment.
                child.Arrange(new Rect(x, y + (rowHeight - d.Height) / 2, d.Width, d.Height));
                x += d.Width;
            }
            y += rowHeight;
            row.Clear();
            rowWidth = 0;
            rowHeight = 0;
        }

        foreach (var child in Children)
        {
            var d = child.DesiredSize;
            if (d.Width <= 0)
            {
                child.Arrange(new Rect(0, y, 0, 0));
                continue;
            }
            if (rowWidth > 0 && rowWidth + d.Width > finalSize.Width + Tolerance) ArrangeRow();
            row.Add(child);
            rowWidth += d.Width;
            rowHeight = Math.Max(rowHeight, d.Height);
        }
        ArrangeRow();
        return finalSize;
    }
}
