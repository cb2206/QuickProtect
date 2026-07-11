using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace QuickProtect.App;

/// <summary>
/// Draws the Aurora aperture mark (outer ring + quick-shutter top arc + inner lens)
/// at runtime and wraps it as a <see cref="WindowIcon"/> for the tray — a port of
/// the macOS <c>makeApertureTemplate</c>, so no binary icon asset is shipped.
/// </summary>
public static class ApertureIcon
{
    public static WindowIcon Create(int size = 32)
    {
        var pixel = new PixelSize(size, size);
        var dpi = new Vector(96, 96);
        using var rtb = new RenderTargetBitmap(pixel, dpi);
        using (var ctx = rtb.CreateDrawingContext())
        {
            var stroke = Brushes.White;
            var pen = new Pen(stroke, Math.Max(1.0, size * 0.10)) { LineCap = PenLineCap.Round };

            var inset = Math.Max(1.0, size * 0.10);
            var bounds = new Rect(inset, inset, size - 2 * inset, size - 2 * inset);
            var center = bounds.Center;

            // Outer ring.
            ctx.DrawEllipse(null, pen, center, bounds.Width / 2, bounds.Height / 2);

            // Inner lens (filled).
            var lensR = bounds.Width * 0.22;
            ctx.DrawEllipse(stroke, null, center, lensR, lensR);

            // Top-right quick-shutter arc.
            var arcPen = new Pen(stroke, Math.Max(1.0, size * 0.10) * 1.7) { LineCap = PenLineCap.Round };
            var r = bounds.Width / 2;
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                Point At(double deg)
                {
                    var rad = deg * Math.PI / 180.0;
                    return new Point(center.X + r * Math.Cos(rad), center.Y - r * Math.Sin(rad));
                }
                g.BeginFigure(At(90), false);
                // Sweep from top (90°) toward upper-right (40°).
                g.ArcTo(At(40), new Size(r, r), 0, false, SweepDirection.Clockwise);
                g.EndFigure(false);
            }
            ctx.DrawGeometry(null, arcPen, geo);
        }

        using var ms = new MemoryStream();
        rtb.Save(ms);
        ms.Position = 0;
        return new WindowIcon(ms);
    }
}
