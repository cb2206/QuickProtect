using System.Runtime.InteropServices;
using FFmpeg.AutoGen.Abstractions;
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
/// screen through reconnects and quality switches (no grey flash), and a broken
/// connection retries with backoff until <see cref="Stop"/>.
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

    // Latest decoded frame (BGRA). Swapped under _frameLock; UI copies under the same lock.
    private readonly object _frameLock = new();
    private byte[]? _frame;
    private int _width, _height, _stride;
    private long _seq;

    private readonly object _ctrlLock = new();
    private Thread? _thread;
    private string? _url;
    private string? _pendingUrl;
    private volatile bool _stop;
    private volatile bool _restart;

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

    /// <summary>Start streaming <paramref name="url"/> (no-op when already on it).</summary>
    public void Start(string url)
    {
        lock (_ctrlLock)
        {
            if (_thread is { IsAlive: true })
            {
                if (url != _url) SwitchUrl(url);
                return;
            }
            _url = url;
            _stop = false;
            _restart = false;
            _thread = new Thread(RunLoop) { IsBackground = true, Name = "QP-Video" };
            _thread.Start();
        }
    }

    /// <summary>
    /// Switch to a new URL in place (quality change / PiP swap). The current
    /// frame stays on screen until the new stream delivers its first frame.
    /// </summary>
    public void SwitchUrl(string url)
    {
        lock (_ctrlLock)
        {
            _pendingUrl = url;
            _restart = true;
        }
    }

    public void Stop()
    {
        Thread? t;
        lock (_ctrlLock)
        {
            _stop = true;
            t = _thread;
            _thread = null;
        }
        t?.Join(3000);
        SetState(VideoState.Idle);
    }

    public void Dispose() => Stop();

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

    /// <summary>Whether at least one frame has ever been decoded (for keep-last-frame UIs).</summary>
    public bool HasFrame
    {
        get { lock (_frameLock) return _frame != null; }
    }

    // MARK: - Decode loop

    private void RunLoop()
    {
        var backoff = TimeSpan.FromMilliseconds(500);
        while (!_stop)
        {
            string url;
            lock (_ctrlLock)
            {
                if (_pendingUrl != null) { _url = _pendingUrl; _pendingUrl = null; }
                _restart = false;
                url = _url!;
            }

            SetState(HasFrame ? State : VideoState.Connecting);
            var ok = false;
            try { ok = RunSession(url); }
            catch (Exception ex) { Log.Line($"[Video] session error: {ex.Message}"); }

            if (_stop) break;
            if (_restart) { backoff = TimeSpan.FromMilliseconds(250); continue; } // deliberate switch
            SetState(VideoState.Connecting);
            // Broken stream: retry with backoff (keeping the last frame on screen).
            Thread.Sleep(ok ? TimeSpan.FromMilliseconds(500) : backoff);
            if (!ok) backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromSeconds(5).Ticks));
        }
    }

    /// <summary>One demux/decode session. Returns true when it ended cleanly (EOF).</summary>
    private unsafe bool RunSession(string url)
    {
        AVFormatContext* fmt = ffmpeg.avformat_alloc_context();
        if (fmt == null) return false;

        // Abort blocking I/O on stop/switch — without this a dead controller
        // connection would hang the thread for the full socket timeout.
        var interrupt = new AVIOInterruptCB_callback(_ => _stop || _restart ? 1 : 0);
        fmt->interrupt_callback.callback = interrupt;

        AVCodecContext* codec = null;
        SwsContext* sws = null;
        AVFrame* frame = null;
        AVFrame* bgra = null;
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

            codec = ffmpeg.avcodec_alloc_context3(decoder);
            ffmpeg.avcodec_parameters_to_context(codec, fmt->streams[vs]->codecpar);
            codec->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
            codec->thread_count = Math.Min(2, Environment.ProcessorCount);
            rc = ffmpeg.avcodec_open2(codec, decoder, null);
            if (rc < 0) return LogAv("avcodec_open2", rc);

            // Audio track (AAC on UniFi streams) — best-effort: a stream without
            // one, or a codec that won't open, plays video-only.
            AVCodec* audioDecoder = null;
            var audioIdx = ffmpeg.av_find_best_stream(fmt, AVMediaType.AVMEDIA_TYPE_AUDIO, -1, vs, &audioDecoder, 0);
            if (audioIdx >= 0 && audioDecoder != null)
            {
                audioCodec = ffmpeg.avcodec_alloc_context3(audioDecoder);
                ffmpeg.avcodec_parameters_to_context(audioCodec, fmt->streams[audioIdx]->codecpar);
                if (ffmpeg.avcodec_open2(audioCodec, audioDecoder, null) < 0)
                {
                    ffmpeg.avcodec_free_context(&audioCodec);
                    audioCodec = null;
                }
            }
            SetHasAudio(audioCodec != null);
            if (audioCodec != null) audioFrame = ffmpeg.av_frame_alloc();
            _sinkFailed = false;

            frame = ffmpeg.av_frame_alloc();
            bgra = ffmpeg.av_frame_alloc();
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

            while (!_stop && !_restart)
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
                    if (_audioActive) DecodeAudio(audioCodec, packet, audioFrame, ref swr, ref sink, ref pcm);
                    ffmpeg.av_packet_unref(packet);
                    continue;
                }
                if (packet->stream_index != vs) { ffmpeg.av_packet_unref(packet); continue; }
                if (!seenKeyframe)
                {
                    if ((packet->flags & ffmpeg.AV_PKT_FLAG_KEY) != 0)
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

                while (ffmpeg.avcodec_receive_frame(codec, frame) == 0)
                {
                    if (!sizeReported && frame->width > 0)
                    {
                        sizeReported = true;
                        VideoSizeKnown?.Invoke(frame->width, frame->height);
                    }

                    sws = ffmpeg.sws_getCachedContext(sws,
                        frame->width, frame->height, (AVPixelFormat)frame->format,
                        frame->width, frame->height, AVPixelFormat.AV_PIX_FMT_BGRA,
                        ffmpeg.SWS_BILINEAR, null, null, null);

                    var stride = frame->width * 4;
                    lock (_frameLock)
                    {
                        var needed = stride * frame->height;
                        if (_frame == null || _frame.Length < needed ||
                            _width != frame->width || _height != frame->height)
                        {
                            _frame = new byte[needed];
                            _width = frame->width;
                            _height = frame->height;
                            _stride = stride;
                        }
                        fixed (byte* dst = _frame)
                        {
                            var dstPlanes = new byte*[] { dst };
                            var dstStrides = new[] { stride };
                            ffmpeg.sws_scale(sws, frame->data, frame->linesize, 0, frame->height,
                                dstPlanes, dstStrides);
                        }
                        _seq++;
                    }
                    ffmpeg.av_frame_unref(frame);

                    // First frame → Playing immediately (macOS DisplayImmediately parity).
                    if (State != VideoState.Playing) SetState(VideoState.Playing);
                    FrameReady?.Invoke();
                }
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
            if (bgra != null) ffmpeg.av_frame_free(&bgra);
            if (sws != null) ffmpeg.sws_freeContext(sws);
            if (codec != null) ffmpeg.avcodec_free_context(&codec);
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
