using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Video;

/// <summary>
/// Platform audio output for the FFmpeg engine: a push sink taking 16-bit
/// interleaved PCM (the port's analog of the macOS AudioRenderer). Owned and
/// driven by the decode thread of one <see cref="VideoStreamClient"/>.
/// </summary>
public interface IAudioSink : IDisposable
{
    /// <summary>Queue <paramref name="bytes"/> bytes of S16 interleaved PCM.</summary>
    void Write(byte[] buffer, int bytes);

    /// <summary>Drop buffered-but-unplayed audio (called when muting mid-stream).</summary>
    void Flush();
}

public static class AudioSink
{
    /// <summary>
    /// Create the platform sink, or null when audio output is unavailable
    /// (missing device, missing libasound, unsupported OS) — the stream then
    /// plays video-only, mirroring the engine's video graceful degradation.
    /// </summary>
    public static IAudioSink? Create(int sampleRate, int channels)
    {
        try
        {
            if (OperatingSystem.IsWindows()) return new WasapiAudioSink(sampleRate, channels);
            if (OperatingSystem.IsLinux()) return new AlsaAudioSink(sampleRate, channels);
            Log.Line("[Audio] no sink for this platform — audio disabled");
        }
        catch (Exception ex)
        {
            Log.Line($"[Audio] sink unavailable: {ex.Message}");
        }
        return null;
    }

    /// <summary>
    /// WASAPI shared-mode output via NAudio. Shared mode auto-converts sample
    /// rate/format to the device mix format (AUTOCONVERTPCM), so the camera's
    /// native rate can be queued directly.
    /// </summary>
    [SupportedOSPlatform("windows")]
    private sealed class WasapiAudioSink : IAudioSink
    {
        private readonly WasapiOut _output;
        private readonly BufferedWaveProvider _buffer;

        public WasapiAudioSink(int sampleRate, int channels)
        {
            _buffer = new BufferedWaveProvider(new WaveFormat(sampleRate, 16, channels))
            {
                // Live view: cap latency and drop rather than lag behind.
                BufferDuration = TimeSpan.FromMilliseconds(800),
                DiscardOnBufferOverflow = true,
            };
            _output = new WasapiOut(AudioClientShareMode.Shared, 100);
            _output.Init(_buffer);
            _output.Play();
        }

        public void Write(byte[] buffer, int bytes) => _buffer.AddSamples(buffer, 0, bytes);

        public void Flush() => _buffer.ClearBuffer();

        public void Dispose()
        {
            try { _output.Stop(); }
            catch (Exception ex) { Log.Line($"[Audio] WASAPI stop: {ex.Message}"); }
            _output.Dispose();
        }
    }

    /// <summary>
    /// ALSA output via libasound (best-effort, like the Linux snapshot
    /// clipboard). Blocking <c>snd_pcm_writei</c> paces the decode thread to
    /// the device clock; underruns are recovered in place.
    /// </summary>
    [SupportedOSPlatform("linux")]
    private sealed class AlsaAudioSink : IAudioSink
    {
        private const string Lib = "libasound.so.2";
        private const int StreamPlayback = 0;      // SND_PCM_STREAM_PLAYBACK
        private const int FormatS16Le = 2;         // SND_PCM_FORMAT_S16_LE
        private const int AccessRwInterleaved = 3; // SND_PCM_ACCESS_RW_INTERLEAVED

        [DllImport(Lib)] private static extern int snd_pcm_open(out IntPtr pcm, string name, int stream, int mode);
        [DllImport(Lib)]
        private static extern int snd_pcm_set_params(IntPtr pcm, int format, int access,
            uint channels, uint rate, int softResample, uint latencyUs);
        [DllImport(Lib)] private static extern unsafe long snd_pcm_writei(IntPtr pcm, byte* buffer, long frames);
        [DllImport(Lib)] private static extern int snd_pcm_recover(IntPtr pcm, int err, int silent);
        [DllImport(Lib)] private static extern int snd_pcm_drop(IntPtr pcm);
        [DllImport(Lib)] private static extern int snd_pcm_prepare(IntPtr pcm);
        [DllImport(Lib)] private static extern int snd_pcm_close(IntPtr pcm);

        private IntPtr _pcm;
        private readonly int _frameBytes;

        public AlsaAudioSink(int sampleRate, int channels)
        {
            _frameBytes = channels * 2;
            var rc = snd_pcm_open(out _pcm, "default", StreamPlayback, 0);
            if (rc < 0) throw new InvalidOperationException($"snd_pcm_open failed ({rc})");
            rc = snd_pcm_set_params(_pcm, FormatS16Le, AccessRwInterleaved,
                (uint)channels, (uint)sampleRate, softResample: 1, latencyUs: 150_000);
            if (rc < 0)
            {
                snd_pcm_close(_pcm);
                _pcm = IntPtr.Zero;
                throw new InvalidOperationException($"snd_pcm_set_params failed ({rc})");
            }
        }

        public unsafe void Write(byte[] buffer, int bytes)
        {
            if (_pcm == IntPtr.Zero) return;
            var frames = bytes / _frameBytes;
            fixed (byte* p = buffer)
            {
                var pos = p;
                while (frames > 0)
                {
                    var written = snd_pcm_writei(_pcm, pos, frames);
                    if (written < 0)
                    {
                        if (snd_pcm_recover(_pcm, (int)written, silent: 1) < 0) return; // device gone
                        continue;
                    }
                    frames -= (int)written;
                    pos += written * _frameBytes;
                }
            }
        }

        public void Flush()
        {
            if (_pcm == IntPtr.Zero) return;
            snd_pcm_drop(_pcm);
            snd_pcm_prepare(_pcm);
        }

        public void Dispose()
        {
            if (_pcm == IntPtr.Zero) return;
            snd_pcm_close(_pcm);
            _pcm = IntPtr.Zero;
        }
    }
}
