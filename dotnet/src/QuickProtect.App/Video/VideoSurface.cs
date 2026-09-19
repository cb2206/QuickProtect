using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Video;

/// <summary>
/// Composited video view: paints the latest decoded frame of a
/// <see cref="VideoStreamClient"/> as ordinary Avalonia content. Because this is
/// a regular control (no native child window), video is clickable, receives
/// gestures, and can be overlaid with any Avalonia element — the properties the
/// macOS app's layer-based rendering has.
///
/// Fit/fill and digital zoom/pan are applied at draw time via the source
/// rectangle, so snapshots and the PiP always see the untouched frame.
/// </summary>
public sealed class VideoSurface : Control
{
    public static readonly StyledProperty<VideoStreamClient?> SourceProperty =
        AvaloniaProperty.Register<VideoSurface, VideoStreamClient?>(nameof(Source));

    /// <summary>Fill (crop to cover) vs fit (letterbox).</summary>
    public static readonly StyledProperty<bool> FillProperty =
        AvaloniaProperty.Register<VideoSurface, bool>(nameof(Fill));

    /// <summary>Digital zoom factor (1 = full frame).</summary>
    public static readonly StyledProperty<double> ZoomProperty =
        AvaloniaProperty.Register<VideoSurface, double>(nameof(Zoom), 1.0);

    /// <summary>Normalized center of the zoom window.</summary>
    public static readonly StyledProperty<double> ZoomCenterXProperty =
        AvaloniaProperty.Register<VideoSurface, double>(nameof(ZoomCenterX), 0.5);

    public static readonly StyledProperty<double> ZoomCenterYProperty =
        AvaloniaProperty.Register<VideoSurface, double>(nameof(ZoomCenterY), 0.5);

    public VideoStreamClient? Source
    {
        get => GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public bool Fill
    {
        get => GetValue(FillProperty);
        set => SetValue(FillProperty, value);
    }

    public double Zoom
    {
        get => GetValue(ZoomProperty);
        set => SetValue(ZoomProperty, value);
    }

    public double ZoomCenterX
    {
        get => GetValue(ZoomCenterXProperty);
        set => SetValue(ZoomCenterXProperty, value);
    }

    public double ZoomCenterY
    {
        get => GetValue(ZoomCenterYProperty);
        set => SetValue(ZoomCenterYProperty, value);
    }

    private WriteableBitmap? _bitmap;
    private long _seq = -1;
    private int _updatePending; // 0/1, Interlocked

    static VideoSurface()
    {
        AffectsRender<VideoSurface>(FillProperty, ZoomProperty, ZoomCenterXProperty, ZoomCenterYProperty);
        SourceProperty.Changed.AddClassHandler<VideoSurface>((s, e) => s.OnSourceChanged(e));
    }

    private void OnSourceChanged(AvaloniaPropertyChangedEventArgs e)
    {
        if (e.OldValue is VideoStreamClient old)
        {
            old.FrameReady -= OnFrameReady;
            old.PlaceholderChanged -= OnPlaceholderChanged;
        }
        _seq = -1;
        _bitmap?.Dispose();   // unmanaged Skia memory — don't wait for the finalizer
        _bitmap = null;
        if (e.NewValue is VideoStreamClient client)
        {
            client.FrameReady += OnFrameReady;
            client.PlaceholderChanged += OnPlaceholderChanged;
            if (client.HasFrame) OnFrameReady(); // adopt an already-running stream instantly
        }
        InvalidateVisual();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        if (Source is { } s)
        {
            s.FrameReady -= OnFrameReady;
            s.PlaceholderChanged -= OnPlaceholderChanged;
        }
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (Source is { } s)
        {
            s.FrameReady -= OnFrameReady; // no double-subscribe
            s.FrameReady += OnFrameReady;
            s.PlaceholderChanged -= OnPlaceholderChanged;
            s.PlaceholderChanged += OnPlaceholderChanged;
            if (s.HasFrame) OnFrameReady();
        }
    }

    private void OnPlaceholderChanged() => Dispatcher.UIThread.Post(InvalidateVisual);

    // Decode thread → coalesced UI update (at most one queued at a time).
    private void OnFrameReady()
    {
        if (Interlocked.Exchange(ref _updatePending, 1) == 1) return;
        Dispatcher.UIThread.Post(() =>
        {
            Interlocked.Exchange(ref _updatePending, 0);
            UpdateBitmap();
        }, DispatcherPriority.Render);
    }

    private void UpdateBitmap()
    {
        var client = Source;
        if (client == null) return;

        // Copy the frame straight into the locked bitmap — no intermediate
        // buffer. If the stream switches resolution between the size query and
        // the copy, the copy reports a mismatch and one retry re-sizes the
        // bitmap; a second failure means another switch is in flight and the
        // next FrameReady will catch up.
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var (w, h) = client.FrameSize;
            if (w <= 0 || h <= 0) return;

            if (_bitmap == null || _bitmap.PixelSize.Width != w || _bitmap.PixelSize.Height != h)
            {
                _bitmap?.Dispose();
                _bitmap = new WriteableBitmap(new PixelSize(w, h), new Vector(96, 96),
                    PixelFormat.Bgra8888, AlphaFormat.Opaque);
            }

            bool copied;
            using (var fb = _bitmap.Lock())
                copied = client.TryCopyFrameTo(fb.Address, fb.RowBytes, w, h, ref _seq);
            if (copied)
            {
                InvalidateVisual();
                return;
            }
            var (nw, nh) = client.FrameSize;
            if (nw == w && nh == h) return; // no new frame — nothing to redraw
        }
    }

    /// <summary>
    /// Decoded placeholder for pre-first-frame rendering (the 2 fps package
    /// lens waits many seconds for its first keyframe). Cached per byte-array
    /// instance so the JPEG is decoded once, not per render pass.
    /// </summary>
    private Bitmap? PlaceholderBitmap()
    {
        var src = Source;
        if (src == null || src.HasFrame) return null;
        var bytes = src.PlaceholderImage;
        if (bytes == null) return null;
        if (!ReferenceEquals(bytes, _placeholderBytes))
        {
            _placeholderBytes = bytes;
            _placeholder?.Dispose();
            try
            {
                using var ms = new MemoryStream(bytes);
                _placeholder = new Bitmap(ms);
            }
            catch (Exception ex)
            {
                Log.Line($"[Snapshot] placeholder decode failed: {ex.Message}");
                _placeholder = null;
            }
        }
        return _placeholder;
    }

    private Bitmap? _placeholder;
    private byte[]? _placeholderBytes;

    public override void Render(DrawingContext context)
    {
        // Live frames always win; the placeholder only covers the gap before
        // the first decode.
        Bitmap? bmp = _bitmap ?? PlaceholderBitmap();
        var bounds = Bounds;
        if (bmp == null || bounds.Width < 1 || bounds.Height < 1) return;

        double srcW = bmp.PixelSize.Width, srcH = bmp.PixelSize.Height;

        // Digital zoom window (normalized center + factor), clamped inside the frame.
        var zoom = Math.Max(1.0, Zoom);
        var winW = srcW / zoom;
        var winH = srcH / zoom;
        var cx = Math.Clamp(ZoomCenterX, winW / srcW / 2, 1 - winW / srcW / 2) * srcW;
        var cy = Math.Clamp(ZoomCenterY, winH / srcH / 2, 1 - winH / srcH / 2) * srcH;
        var src = new Rect(cx - winW / 2, cy - winH / 2, winW, winH);

        Rect dest;
        var srcAspect = src.Width / src.Height;
        var dstAspect = bounds.Width / bounds.Height;
        if (Fill)
        {
            // Crop the source further so it covers the control (center crop).
            if (srcAspect > dstAspect)
            {
                var cropW = src.Height * dstAspect;
                src = new Rect(src.X + (src.Width - cropW) / 2, src.Y, cropW, src.Height);
            }
            else
            {
                var cropH = src.Width / dstAspect;
                src = new Rect(src.X, src.Y + (src.Height - cropH) / 2, src.Width, cropH);
            }
            dest = new Rect(bounds.Size);
        }
        else
        {
            // Letterbox: largest source-aspect rect inside the control.
            double dw, dh;
            if (srcAspect > dstAspect) { dw = bounds.Width; dh = bounds.Width / srcAspect; }
            else { dh = bounds.Height; dw = bounds.Height * srcAspect; }
            dest = new Rect((bounds.Width - dw) / 2, (bounds.Height - dh) / 2, dw, dh);
        }

        context.DrawImage(bmp, src, dest);
    }
}
