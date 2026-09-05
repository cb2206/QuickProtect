using System.Runtime.InteropServices;
using FFmpeg.AutoGen.Abstractions;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Video;

public enum VideoState
{
    Idle,
    Connecting,
    Playing,
    Failed
}

/// <summary>
/// One live RTSP stream: demux + decode on a dedicated thread, latest-frame-wins
/// BGRA buffer for the UI. Mirrors the macOS RTSPClient behaviors that matter:
/// the first decoded frame is displayed immediately, the last frame is kept on
/// screen through reconnects, and a broken connection retries with backoff until
/// <see cref="Stop"/>.
///
/// Quality switches are seamless: the old session keeps decoding (live picture)
/// while the new one connects and waits for its first keyframe on a second
/// thread; the new session takes over the frame buffer at its first decoded
/// frame, which retires the old session. Each session carries a generation
/// number — only the highest generation that has produced a frame may publish.
/// </summary>
public sealed class VideoStreamClient : IDisposable
{
    /// <summary>A new frame is available (raised on the decode thread, coalesce in the UI).</summary>
    public event Action? FrameReady;

    /// <summary>State transitions (raised on the decode thread).</summary>
    public event Action<VideoState>? StateChanged;

    /// <summary>First frame of a session decoded — reports the native video size.</summary>
    public event Action<int, int>? VideoSizeKnown;

    /// <summary>An audio track was found (or lost) for the current session.</summary>
    public event Action<bool>? HasAudioChanged;

    public VideoState State { get; private set; } = VideoState.Idle;

    /// <summary>True while the current session carries a decodable audio track.</summary>
    public bool HasAudio { get; private set; }

    /// <summary>
    /// Controller-provided JPEG shown by <see cref="VideoSurface"/> while no
    /// frame has been decoded yet. Set for streams whose first keyframe is many
    /// seconds away (the 2 fps package lens joins mid-GOP and can't paint until
    /// the next IDR). Raw encoded bytes — the client stays UI-toolkit-free.
    /// </summary>
    public byte[]? PlaceholderImage { get; private set; }

    /// <summary>Placeholder set (raised on the setter's thread, marshal in the UI).</summary>
    public event Action? PlaceholderChanged;

    public void SetPlaceholder(byte[] jpeg)
    {
        PlaceholderImage = jpeg;
        PlaceholderChanged?.Invoke();
    }

    // Latest decoded frame (BGRA). Swapped under _frameLock; UI copies under the same lock.
    private readonly object _frameLock = new();
    private byte[]? _frame;
    private int _width, _height, _stride;
    private long _seq;

    private readonly object _ctrlLock = new();
    private readonly List<(int Gen, Thread Thread)> _threads = new();
    private string? _url;
    private volatile bool _stop;
    /// <summary>Set by <see cref="Stop"/> so a session sleeping in its reconnect backoff wakes at once.</summary>
    private readonly ManualResetEventSlim _wake = new(false);

    /// <summary>
    /// Frames beyond this edge length are refused. FFmpeg's own decoders allow
    /// up to 16384², i.e. a 1 GiB BGRA buffer per reconnect — a hostile or
    /// broken stream must not be able to drive the app into that.
    /// </summary>
    private const int MaxDimension = 8192;

    // Session generations (seamless switching). _latestGen is the newest session
    // started; _paintGen is the one owning the frame buffer (bumped under
    // _frameLock when a newer session decodes its first frame). An old session
    // retires once outpainted, or after the grace window if the new one never
    // paints (bad URL, dead substream) — then the last frame stays on screen and
    // the new session keeps retrying, which is the old non-seamless behavior.
    private volatile int _latestGen;
    private volatile int _paintGen;
    private long _switchDeadlineTicks;
    private static readonly TimeSpan SwitchGrace = TimeSpan.FromSeconds(10);

    // Deferred actions for quality switches: each entry runs once every session
    // with Gen <= Ceiling has fully ended (the coordinator releases the old
    // substream allocation there — releasing earlier would kill the old stream
    // mid-handover and freeze the picture).
    private readonly List<(int Ceiling, Action Done)> _handoffs = new();

    // Audio routing (macOS RTSPClient parity): audio is decoded and rendered
    // only while a focused/pinned view marks this client active; muted by
    // default. Flags are set from the UI thread, consumed on the decode thread.
    private volatile bool _audioActive;
    private volatile bool _audioMuted = true;
    private volatile bool _audioFlush;
    private bool _sinkFailed; // decode-thread only; reset per session

    /// <summary>
    /// Route audio output to this client (the focused/pinned view) or release
    /// it. The sink exists only while active — inactive streams skip audio
    /// decoding entirely.
    /// </summary>
    public void SetAudioActive(bool active) => _audioActive = active;

    /// <summary>Mute or unmute output. Takes effect immediately; decoding continues.</summary>
    public void SetMuted(bool muted)
    {
        if (muted && !_audioMuted) _audioFlush = true; // drop what's queued
        _audioMuted = muted;
    }

    // Render pause (stream keep-alive grace). While paused, compressed video
    // packets are buffered instead of decoded so a hidden panel costs no decode
    // CPU; the flag is set from the UI thread, consumed on the decode thread.
    private volatile bool _renderPaused;

    /// <summary>
    /// Pause or resume decode while the stream stays connected. Used for the
    /// keep-alive grace after the panel closes: decoding frames nobody sees is
    /// wasted CPU, but the connection must survive so a quick reopen is
    /// instant. While paused, compressed packets are buffered from the most
    /// recent keyframe (<see cref="PausedGopBuffer"/>); resume burst-decodes
    /// them, catching the picture up to live immediately. If nothing replayable
    /// was buffered (paused mid-GOP, or the buffer overflowed), the last frame
    /// stays on screen and decoding waits for the next keyframe — feeding
    /// P-frames whose references were never decoded would only produce garbage.
    /// </summary>
    public void SetRenderPaused(bool paused) => _renderPaused = paused;

    /// <summary>
    /// Start streaming <paramref name="url"/> (no-op when already on it). When a
    /// different URL is already playing, switches seamlessly: the old session
    /// keeps rendering until the new one produces its first frame.
    /// <paramref name="onPreviousSessionEnded"/> runs once every pre-switch
    /// session has fully ended (or immediately when there was nothing to switch
    /// from) — the coordinator releases the old substream allocation there.
    /// </summary>
    public void Start(string url, Action? onPreviousSessionEnded = null)
    {
        Action? fireNow = null;
        lock (_ctrlLock)
        {
            if (!_stop && _threads.Any(t => t.Thread.IsAlive))
            {
                if (url != _url)
                {
                    _url = url;
                    if (onPreviousSessionEnded != null)
                        _handoffs.Add((_latestGen, onPreviousSessionEnded));
                    Volatile.Write(ref _switchDeadlineTicks, (DateTime.UtcNow + SwitchGrace).Ticks);
                    StartSessionThreadLocked(url);
                }
                else
                {
                    fireNow = onPreviousSessionEnded; // same URL: nothing to hand over
                }
            }
            else
            {
                _threads.Clear();
                _url = url;
                _stop = false;
                _wake.Reset();
                StartSessionThreadLocked(url);
                fireNow = onPreviousSessionEnded; // no previous session
            }
        }
        fireNow?.Invoke();
    }

    private void StartSessionThreadLocked(string url)
    {
        var gen = ++_latestGen;
        var thread = new Thread(() => RunLoop(url, gen)) { IsBackground = true, Name = "QP-Video" };
        _threads.Add((gen, thread));
        thread.Start();
    }

    /// <summary>
    /// Stop streaming. Signals the session threads and returns immediately:
    /// callers are on the UI thread (tile release, panel close for every tile,
    /// quit), and a session blocked in a socket read, a reconnect backoff or an
    /// audio write must not stall them. The thread exits on its own (the
    /// interrupt callback aborts blocking I/O); <see cref="Dispose"/> waits.
    /// </summary>
    public void Stop()
    {
        lock (_ctrlLock) _stop = true;
        _wake.Set();
        SetState(VideoState.Idle);
    }

    /// <summary>
    /// The stream's allocation could not be (re)created — the coordinator will
    /// retry, but the UI should drop its spinner meanwhile (the last frame, if
    /// any, stays on screen).
    /// </summary>
    public void ReportFailure() => SetState(VideoState.Failed);

    /// <summary>Stop and wait (briefly) for the session threads to end — app exit only.</summary>
    public void Dispose()
    {
        Stop();
        Thread[] threads;
        lock (_ctrlLock) threads = _threads.Select(t => t.Thread).ToArray();
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(1);
        foreach (var t in threads)
        {
            var remaining = deadline - DateTime.UtcNow;
            if (remaining > TimeSpan.Zero) t.Join(remaining);
        }
    }

    /// <summary>
    /// Copy the latest frame into <paramref name="buffer"/> (reallocated when too
    /// small). Returns false when there is no new frame since <paramref name="seenSeq"/>.
    /// </summary>
    public bool TryCopyFrame(ref byte[]? buffer, ref long seenSeq, out int width, out int height, out int stride)
    {
        lock (_frameLock)
        {
            width = _width;
            height = _height;
            stride = _stride;
            if (_frame == null || _seq == seenSeq) return false;
            var needed = _stride * _height;
            if (buffer == null || buffer.Length < needed) buffer = new byte[needed];
            Array.Copy(_frame, buffer, needed);
            seenSeq = _seq;
            return true;
        }
    }

    /// <summary>Native size of the latest decoded frame (0×0 before the first frame).</summary>
    public (int Width, int Height) FrameSize
    {
        get { lock (_frameLock) return (_width, _height); }
    }

    /// <summary>
    /// Copy the latest frame straight into caller-owned memory (e.g. a locked
    /// WriteableBitmap), skipping the intermediate managed buffer that
    /// <see cref="TryCopyFrame"/> needs. Returns false when there is no new
    /// frame since <paramref name="seenSeq"/>, or when the frame no longer
    /// matches the expected size (stream switched resolution) — the caller
    /// should re-read <see cref="FrameSize"/> and retry with a matching target.
    /// </summary>
    public bool TryCopyFrameTo(IntPtr dest, int destRowBytes, int expectedWidth, int expectedHeight,
        ref long seenSeq)
    {
        lock (_frameLock)
        {
            if (_frame == null || _seq == seenSeq) return false;
            if (_width != expectedWidth || _height != expectedHeight) return false;
            if (destRowBytes == _stride)
            {
                Marshal.Copy(_frame, 0, dest, _stride * _height);
            }
            else
            {
                for (var row = 0; row < _height; row++)
                    Marshal.Copy(_frame, row * _stride, dest + row * destRowBytes, _stride);
            }
            seenSeq = _seq;
            return true;
        }
    }

    /// <summary>Whether at least one frame has ever been decoded (for keep-last-frame UIs).</summary>
    public bool HasFrame
    {
        get { lock (_frameLock) return _frame != null; }
    }

    // MARK: - Hardware decode (D3D11VA on Windows, VAAPI on Linux)

    // Platform hardware decoder surface. Decode runs on the GPU's fixed-function
    // block and only the finished NV12 frame is copied back — the software
    // H.264/HEVC decode this replaces was the largest CPU cost per stream.
    private static readonly AVHWDeviceType HwDeviceType = OperatingSystem.IsWindows()
        ? AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA
        : AVHWDeviceType.AV_HWDEVICE_TYPE_VAAPI;

    private static readonly AVPixelFormat HwPixelFormat = OperatingSystem.IsWindows()
        ? AVPixelFormat.AV_PIX_FMT_D3D11
        : AVPixelFormat.AV_PIX_FMT_VAAPI;

    // Static delegate so the native function pointer stays valid for the
    // process lifetime (same reason the interrupt callback is kept alive).
    private static readonly unsafe AVCodecContext_get_format PickHwFormat = GetHwFormat;

    /// <summary>
    /// FFmpeg's negotiation callback: prefer the platform hardware surface when
    /// the decoder offers it. When hwaccel init fails (no GPU decoder for this
    /// codec/profile — common in VMs), FFmpeg calls again without the hardware
    /// format in the list and the first software format wins, so the session
    /// degrades to software decode instead of erroring.
    /// </summary>
    private static unsafe AVPixelFormat GetHwFormat(AVCodecContext* ctx, AVPixelFormat* formats)
    {
        for (var p = formats; *p != AVPixelFormat.AV_PIX_FMT_NONE; p++)
            if (*p == HwPixelFormat)
                return HwPixelFormat;
        return *formats;
    }

    // One-shot log flags (the session loop reconnects forever — per-session
    // logging would spam).
    private static int _hwLogged;

    // MARK: - Decode loop

    /// <summary>
    /// True when this session generation must retire: a newer session owns the
    /// frame buffer, or a newer one exists and the handover grace has expired.
    /// </summary>
    private bool Superseded(int gen)
    {
        if (gen < _paintGen) return true;
        if (gen == _latestGen) return false;
        return DateTime.UtcNow.Ticks > Volatile.Read(ref _switchDeadlineTicks);
    }

    /// <summary>Fires handoff actions whose sessions have all ended (see <see cref="_handoffs"/>).</summary>
    private void OnSessionThreadExit(int gen)
    {
        var fire = new List<Action>();
        lock (_ctrlLock)
        {
            _threads.RemoveAll(t => t.Gen == gen);
            for (var i = _handoffs.Count - 1; i >= 0; i--)
            {
                var (ceiling, done) = _handoffs[i];
                if (gen > ceiling || _threads.Any(t => t.Gen <= ceiling)) continue;
                fire.Add(done);
                _handoffs.RemoveAt(i);
            }
        }
        foreach (var done in fire) done();
    }

    private void RunLoop(string url, int gen)
    {
        try
        {
            var backoff = TimeSpan.FromMilliseconds(500);
            while (!_stop && !Superseded(gen))
            {
                SetState(HasFrame ? State : VideoState.Connecting);
                var ok = false;
                try { ok = RunSession(url, gen); }
                catch (Exception ex) { Log.Line($"[Video] session error: {ex.Message}"); }

                if (_stop || Superseded(gen)) break;
                // Broken stream: retry with backoff (keeping the last frame on
                // screen). Only the painting session flips the UI to Connecting —
                // a warming-up switch target must not spinner over a live picture.
                if (gen == _paintGen) SetState(VideoState.Connecting);
                // Interruptible: Stop() sets _wake so the thread exits at once.
                _wake.Wait(ok ? TimeSpan.FromMilliseconds(500) : backoff);
                if (!ok) backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromSeconds(5).Ticks));
            }
        }
        finally
        {
            OnSessionThreadExit(gen);
        }
    }

    /// <summary>One demux/decode session. Returns true when it ended cleanly (EOF).</summary>
    private unsafe bool RunSession(string url, int gen)
    {
        AVFormatContext* fmt = ffmpeg.avformat_alloc_context();
        if (fmt == null) return false;

        // Abort blocking I/O on stop/supersession — without this a dead controller
        // connection would hang the thread for the full socket timeout.
        var interrupt = new AVIOInterruptCB_callback(_ => _stop || Superseded(gen) ? 1 : 0);
        fmt->interrupt_callback.callback = interrupt;

        AVCodecContext* codec = null;
        AVBufferRef* hwDevice = null;
        SwsContext* sws = null;
        AVFrame* frame = null;
        AVFrame* hwTransfer = null;
        AVPacket* packet = null;
        AVCodecContext* audioCodec = null;
        AVFrame* audioFrame = null;
        SwrContext* swr = null;
        IAudioSink? sink = null;
        byte[]? pcm = null;
        try
        {
            AVDictionary* opts = null;
            ffmpeg.av_dict_set(&opts, "rtsp_transport", "tcp", 0);   // interleaved, tunnel-friendly
            ffmpeg.av_dict_set(&opts, "fflags", "nobuffer", 0);      // low latency: no demux buffering
            ffmpeg.av_dict_set(&opts, "flags", "low_delay", 0);
            ffmpeg.av_dict_set(&opts, "analyzeduration", "700000", 0); // 0.7s max probe — fast startup
            ffmpeg.av_dict_set(&opts, "timeout", "5000000", 0);      // 5s socket timeout (µs)

            var rc = ffmpeg.avformat_open_input(&fmt, url, null, &opts);
            ffmpeg.av_dict_free(&opts);
            if (rc < 0) return LogAv("open_input", rc);

            rc = ffmpeg.avformat_find_stream_info(fmt, null);
            if (rc < 0) return LogAv("find_stream_info", rc);

            AVCodec* decoder = null;
            var vs = ffmpeg.av_find_best_stream(fmt, AVMediaType.AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
            if (vs < 0 || decoder == null) return LogAv("find_best_stream", vs);

            var par = fmt->streams[vs]->codecpar;
            if (par->width > MaxDimension || par->height > MaxDimension)
            {
                Log.Line($"[Video] refusing {par->width}x{par->height} stream (limit {MaxDimension})");
                return false;
            }
            codec = ffmpeg.avcodec_alloc_context3(decoder);
            rc = ffmpeg.avcodec_parameters_to_context(codec, par);
            if (rc < 0) return LogAv("parameters_to_context", rc);
            codec->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
            codec->thread_count = Math.Min(2, Environment.ProcessorCount);

            // Hardware decode when the platform offers a device; failure at any
            // stage (device creation here, hwaccel init later via GetHwFormat)
            // falls back to software without ending the session.
            if (ffmpeg.av_hwdevice_ctx_create(&hwDevice, HwDeviceType, null, null, 0) >= 0)
            {
                codec->hw_device_ctx = ffmpeg.av_buffer_ref(hwDevice);
                codec->get_format = PickHwFormat;
                if (Interlocked.Exchange(ref _hwLogged, 1) == 0)
                    Log.Line($"[Video] hardware decode device ready ({HwDeviceType})");
            }
            else if (Interlocked.Exchange(ref _hwLogged, 1) == 0)
            {
                Log.Line($"[Video] no {HwDeviceType} device — software decode");
            }

            rc = ffmpeg.avcodec_open2(codec, decoder, null);
            if (rc < 0) return LogAv("avcodec_open2", rc);

            // Audio track (AAC on UniFi streams) — best-effort: a stream without
            // one, or a codec that won't open, plays video-only.
            AVCodec* audioDecoder = null;
            var audioIdx = ffmpeg.av_find_best_stream(fmt, AVMediaType.AVMEDIA_TYPE_AUDIO, -1, vs, &audioDecoder, 0);
            if (audioIdx >= 0 && audioDecoder != null)
            {
                audioCodec = ffmpeg.avcodec_alloc_context3(audioDecoder);
                if (ffmpeg.avcodec_parameters_to_context(audioCodec, fmt->streams[audioIdx]->codecpar) < 0
                    || ffmpeg.avcodec_open2(audioCodec, audioDecoder, null) < 0)
                {
                    ffmpeg.avcodec_free_context(&audioCodec);
                    audioCodec = null;
                }
            }
            SetHasAudio(audioCodec != null);
            if (audioCodec != null) audioFrame = ffmpeg.av_frame_alloc();
            _sinkFailed = false;

            frame = ffmpeg.av_frame_alloc();
            hwTransfer = ffmpeg.av_frame_alloc();
            packet = ffmpeg.av_packet_alloc();
            var sizeReported = false;
            // Joining an RTSP stream mid-GOP means P/B-frames reference frames we
            // never received; decoding them paints grey concealment ghosting over
            // the (good) kept frame until the next IDR. So drop everything until
            // the first keyframe — the last frame stays on screen meanwhile,
            // matching the macOS client's wait-for-IDR behavior. Safety valve:
            // if no keyframe shows up within 15s, decode anyway (and log it).
            var seenKeyframe = false;
            var keyframeDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
            // Keep-alive grace: per-session GOP buffer filled while _renderPaused
            // (a reconnect while paused starts over — the old session's packets
            // are useless against a fresh decoder).
            var pausedGop = new PausedGopBuffer();
            var wasPaused = false;
            // Set by ReceiveFrames when the decoder produces a frame the engine
            // refuses (oversized, or no scaler for its pixel format); the
            // session ends rather than decoding into nothing.
            var refused = false;

            // Drain every decoded frame into the latest-wins BGRA buffer. The
            // codec/frame pointers come in as parameters: capturing them would
            // forbid the &codec/&frame cleanup below (CS1686).
            void ReceiveFrames(AVCodecContext* dec, AVFrame* frm, AVFrame* hwSw)
            {
                while (ffmpeg.avcodec_receive_frame(dec, frm) == 0)
                {
                    // Hardware-decoded frames live on a GPU surface; download to
                    // system memory (NV12) for the sws conversion below.
                    var src = frm;
                    if (frm->format == (int)HwPixelFormat)
                    {
                        if (ffmpeg.av_hwframe_transfer_data(hwSw, frm, 0) < 0)
                        {
                            ffmpeg.av_frame_unref(frm);
                            continue;
                        }
                        src = hwSw;
                    }

                    if (!sizeReported && src->width > 0 && gen >= _paintGen)
                    {
                        sizeReported = true;
                        VideoSizeKnown?.Invoke(src->width, src->height);
                    }

                    if (src->width > MaxDimension || src->height > MaxDimension || src->width <= 0 || src->height <= 0)
                    {
                        Log.Line($"[Video] refusing {src->width}x{src->height} frame (limit {MaxDimension})");
                        if (src == hwSw) ffmpeg.av_frame_unref(hwSw);
                        ffmpeg.av_frame_unref(frm);
                        refused = true;
                        return;
                    }
                    sws = ffmpeg.sws_getCachedContext(sws,
                        src->width, src->height, (AVPixelFormat)src->format,
                        src->width, src->height, AVPixelFormat.AV_PIX_FMT_BGRA,
                        ffmpeg.SWS_BILINEAR, null, null, null);
                    if (sws == null)
                    {
                        // No scaler for this pixel format: sws_scale on null is a
                        // native crash, not a managed exception.
                        Log.Line($"[Video] no scaler for pixel format {src->format}");
                        if (src == hwSw) ffmpeg.av_frame_unref(hwSw);
                        ffmpeg.av_frame_unref(frm);
                        refused = true;
                        return;
                    }

                    var stride = src->width * 4;
                    var published = false;
                    lock (_frameLock)
                    {
                        // Seamless-switch gate: only the newest generation that
                        // has reached this point may publish. Decoding the first
                        // frame IS the takeover — the outpainted session retires
                        // via Superseded() in its loop conditions.
                        if (gen >= _paintGen)
                        {
                            _paintGen = gen;
                            var needed = stride * src->height;
                            if (_frame == null || _frame.Length < needed ||
                                _width != src->width || _height != src->height)
                            {
                                _frame = new byte[needed];
                                _width = src->width;
                                _height = src->height;
                                _stride = stride;
                            }
                            fixed (byte* dst = _frame)
                            {
                                var dstPlanes = new byte*[] { dst };
                                var dstStrides = new[] { stride };
                                ffmpeg.sws_scale(sws, src->data, src->linesize, 0, src->height,
                                    dstPlanes, dstStrides);
                            }
                            _seq++;
                            published = true;
                        }
                    }
                    if (src == hwSw) ffmpeg.av_frame_unref(hwSw);
                    ffmpeg.av_frame_unref(frm);
                    if (!published) return; // outpainted by a newer session: stop draining

                    // First frame → Playing immediately (macOS DisplayImmediately parity).
                    if (State != VideoState.Playing) SetState(VideoState.Playing);
                    FrameReady?.Invoke();
                }
            }

            // Decode one buffered packet from the paused GOP (resume burst).
            void SendBuffered(AVCodecContext* dec, AVFrame* frm, AVFrame* hwSw, byte[] data)
            {
                var pkt = ffmpeg.av_packet_alloc();
                if (pkt == null) return;
                try
                {
                    if (ffmpeg.av_new_packet(pkt, data.Length) < 0) return;
                    Marshal.Copy(data, 0, (IntPtr)pkt->data, data.Length);
                    if (ffmpeg.avcodec_send_packet(dec, pkt) >= 0) ReceiveFrames(dec, frm, hwSw);
                }
                finally
                {
                    ffmpeg.av_packet_free(&pkt);
                }
            }

            while (!_stop && !Superseded(gen))
            {
                // Audio routing changed: tear the sink down when released so an
                // unfocused stream costs nothing, flush on mute.
                if (sink != null && !_audioActive) { sink.Dispose(); sink = null; }
                if (_audioFlush) { sink?.Flush(); _audioFlush = false; }

                rc = ffmpeg.av_read_frame(fmt, packet);
                if (rc < 0)
                    return rc == ffmpeg.AVERROR_EOF; // EOF = clean end; else broken

                if (audioCodec != null && packet->stream_index == audioIdx)
                {
                    // Audio follows the painting session only — a warming-up
                    // switch target must not double the soundtrack.
                    if (_audioActive && gen == _paintGen)
                        DecodeAudio(audioCodec, packet, audioFrame, ref swr, ref sink, ref pcm);
                    ffmpeg.av_packet_unref(packet);
                    continue;
                }
                if (packet->stream_index != vs) { ffmpeg.av_packet_unref(packet); continue; }
                var isKeyframe = (packet->flags & ffmpeg.AV_PKT_FLAG_KEY) != 0;

                // Keep-alive grace: buffer instead of decode while the panel is
                // hidden. Only materialize packets the buffer will keep — copying
                // mid-GOP packets it discards anyway is pure GC churn.
                if (_renderPaused)
                {
                    wasPaused = true;
                    if (pausedGop.WantsPacket(isKeyframe))
                    {
                        var data = new byte[packet->size];
                        Marshal.Copy((IntPtr)packet->data, data, 0, packet->size);
                        pausedGop.Add(data, isKeyframe);
                    }
                    ffmpeg.av_packet_unref(packet);
                    continue;
                }
                if (wasPaused)
                {
                    wasPaused = false;
                    var gop = pausedGop.Drain();
                    if (gop.Count > 0)
                    {
                        // Burst-decode the buffered GOP (it starts at a keyframe)
                        // so the picture lands on live immediately.
                        seenKeyframe = true;
                        foreach (var data in gop) SendBuffered(codec, frame, hwTransfer, data);
                    }
                    else
                    {
                        // Nothing replayable (paused mid-GOP, or the GOP overflowed
                        // the cap): hold the last frame and wait for the next keyframe.
                        seenKeyframe = false;
                        keyframeDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
                    }
                }

                if (!seenKeyframe)
                {
                    if (isKeyframe)
                    {
                        seenKeyframe = true;
                    }
                    else if (DateTime.UtcNow > keyframeDeadline)
                    {
                        Log.Line("[Video] no keyframe within 15s — decoding mid-GOP");
                        seenKeyframe = true;
                    }
                    else
                    {
                        ffmpeg.av_packet_unref(packet);
                        continue;
                    }
                }
                rc = ffmpeg.avcodec_send_packet(codec, packet);
                ffmpeg.av_packet_unref(packet);
                if (rc < 0 && rc != ffmpeg.AVERROR(ffmpeg.EAGAIN)) continue; // tolerate glitches

                ReceiveFrames(codec, frame, hwTransfer);
                if (refused) return false;
            }
            return true;
        }
        finally
        {
            sink?.Dispose();
            if (swr != null) ffmpeg.swr_free(&swr);
            if (audioFrame != null) ffmpeg.av_frame_free(&audioFrame);
            if (audioCodec != null) ffmpeg.avcodec_free_context(&audioCodec);
            if (packet != null) ffmpeg.av_packet_free(&packet);
            if (frame != null) ffmpeg.av_frame_free(&frame);
            if (hwTransfer != null) ffmpeg.av_frame_free(&hwTransfer);
            if (sws != null) ffmpeg.sws_freeContext(sws);
            if (codec != null) ffmpeg.avcodec_free_context(&codec);
            if (hwDevice != null) ffmpeg.av_buffer_unref(&hwDevice);
            if (fmt != null) ffmpeg.avformat_close_input(&fmt);
            GC.KeepAlive(interrupt);
        }
    }

    /// <summary>
    /// Decode one audio packet and queue the PCM on the sink. The resampler and
    /// sink are created lazily from the first decoded frame's real parameters
    /// (planar float AAC → interleaved S16, up to stereo, native rate).
    /// </summary>
    private unsafe void DecodeAudio(AVCodecContext* codec, AVPacket* packet, AVFrame* frame,
        ref SwrContext* swr, ref IAudioSink? sink, ref byte[]? pcm)
    {
        if (ffmpeg.avcodec_send_packet(codec, packet) < 0) return; // tolerate glitches
        while (ffmpeg.avcodec_receive_frame(codec, frame) == 0)
        {
            var outChannels = Math.Min(2, frame->ch_layout.nb_channels);
            if (swr == null)
            {
                AVChannelLayout outLayout;
                ffmpeg.av_channel_layout_default(&outLayout, outChannels);
                fixed (SwrContext** swrPtr = &swr)
                {
                    if (ffmpeg.swr_alloc_set_opts2(swrPtr,
                            &outLayout, AVSampleFormat.AV_SAMPLE_FMT_S16, frame->sample_rate,
                            &frame->ch_layout, (AVSampleFormat)frame->format, frame->sample_rate,
                            0, null) < 0 || ffmpeg.swr_init(swr) < 0)
                    {
                        ffmpeg.av_frame_unref(frame);
                        continue;
                    }
                }
            }
            if (sink == null && !_sinkFailed)
            {
                sink = CreateSink(codec, frame->sample_rate, outChannels);
                _sinkFailed = sink == null; // don't retry every frame
            }

            var maxSamples = ffmpeg.swr_get_out_samples(swr, frame->nb_samples);
            var needed = maxSamples * outChannels * 2;
            if (pcm == null || pcm.Length < needed) pcm = new byte[needed];
            fixed (byte* dst = pcm)
            {
                var outPlane = dst;
                var got = ffmpeg.swr_convert(swr, &outPlane, maxSamples,
                    frame->extended_data, frame->nb_samples);
                if (got > 0 && !_audioMuted) sink?.Write(pcm, got * outChannels * 2);
            }
            ffmpeg.av_frame_unref(frame);
        }
    }

    private unsafe IAudioSink? CreateSink(AVCodecContext* codec, int sampleRate, int channels)
    {
        var sink = AudioSink.Create(sampleRate, channels);
        if (sink != null)
            Log.Line($"[Audio] {ffmpeg.avcodec_get_name(codec->codec_id)} " +
                     $"{sampleRate}Hz {channels}ch → sink started (muted={_audioMuted})");
        return sink;
    }

    private void SetHasAudio(bool has)
    {
        if (HasAudio == has) return;
        HasAudio = has;
        HasAudioChanged?.Invoke(has);
    }

    private static bool LogAv(string what, int rc)
    {
        Log.Line($"[Video] {what} failed: {AvError(rc)}");
        return false;
    }

    private static unsafe string AvError(int rc)
    {
        var buf = stackalloc byte[256];
        ffmpeg.av_strerror(rc, buf, 256);
        return Marshal.PtrToStringAnsi((IntPtr)buf) ?? rc.ToString();
    }

    private void SetState(VideoState s)
    {
        if (State == s) return;
        State = s;
        StateChanged?.Invoke(s);
    }
}
