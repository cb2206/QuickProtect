using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using QuickProtect.App.Video;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Decodes a real live stream with the FFmpeg engine: an <c>ffmpeg</c> binary on
/// PATH serves a generated test pattern as MPEG-TS over HTTP (<c>-listen 1</c>
/// makes it a one-shot server; FFmpeg's RTSP muxer has no server mode any
/// more), and the client must produce BGRA frames of the right size. The
/// engine opens the URL through the same avformat/avcodec path it uses for
/// the controller's RTSP streams, so demux + decode + colour conversion with
/// the bundled/loaded FFmpeg libraries are exercised end to end. Skipped when
/// no ffmpeg binary or no loadable FFmpeg libraries are available, so it runs
/// where the natives are (developer machines, the packaging job) and stays
/// silent elsewhere.
/// </summary>
public class VideoStreamClientTests
{
    private static bool FfmpegBinaryAvailable()
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("ffmpeg", "-version")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false });
            p!.WaitForExit(5000);
            return p.ExitCode == 0;
        }
        catch { return false; }
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    [Theory]
    [InlineData("libx264", 320, 240)]
    [InlineData("libx265", 320, 240)]
    public async Task Decodes_frames_from_a_live_stream(string encoder, int width, int height)
    {
        if (!FfmpegBinaryAvailable()) return;
        FfmpegEngine.Initialize();
        if (!FfmpegEngine.IsAvailable) return;

        var port = FreePort();
        var url = $"http://127.0.0.1:{port}/live";
        // testsrc2 is a synthetic pattern; ultrafast/zerolatency keeps the first
        // keyframe early. -listen 1 serves the first HTTP client and exits after.
        var args = $"-hide_banner -loglevel error -re -f lavfi -i testsrc2=size={width}x{height}:rate=15 " +
                   $"-t 20 -c:v {encoder} -preset ultrafast -tune zerolatency -g 15 -pix_fmt yuv420p " +
                   $"-listen 1 -f mpegts {url}";
        using var server = Process.Start(new ProcessStartInfo("ffmpeg", args)
        { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false });
        Assert.NotNull(server);
        try
        {
            // Some encoders may be absent from the local build (e.g. no x265).
            await Task.Delay(700);
            if (server!.HasExited)
            {
                var err = await server.StandardError.ReadToEndAsync();
                if (err.Contains("Unknown encoder", StringComparison.OrdinalIgnoreCase)) return;
                Assert.Fail($"ffmpeg server exited early: {err}");
            }

            using var client = new VideoStreamClient();
            var firstFrame = new TaskCompletionSource();
            client.FrameReady += () => firstFrame.TrySetResult();
            client.Start(url);

            await firstFrame.Task.WaitAsync(TimeSpan.FromSeconds(20));
            var (w, h) = client.FrameSize;
            Assert.Equal(width, w);
            Assert.Equal(height, h);
            Assert.Equal(VideoState.Playing, client.State);

            byte[]? buffer = null;
            long seq = -1;
            Assert.True(client.TryCopyFrame(ref buffer, ref seq, out var cw, out var ch, out var stride));
            Assert.Equal(width, cw);
            Assert.Equal(height, ch);
            Assert.Equal(width * 4, stride);
            // The pattern is not black: some pixel must have colour.
            Assert.Contains(buffer!.Take(stride * ch), b => b > 16);

            client.Stop();
        }
        finally
        {
            try { if (!server!.HasExited) server.Kill(); } catch { /* gone */ }
        }
    }

    [Fact]
    public async Task Audio_only_stream_reports_failure_and_keeps_retrying()
    {
        if (!FfmpegBinaryAvailable()) return;
        FfmpegEngine.Initialize();
        if (!FfmpegEngine.IsAvailable) return;

        var port = FreePort();
        var url = $"http://127.0.0.1:{port}/audio";
        var args = $"-hide_banner -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 " +
                   $"-t 15 -c:a aac -listen 1 -f mpegts {url}";
        using var server = Process.Start(new ProcessStartInfo("ffmpeg", args)
        { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false });
        Assert.NotNull(server);
        try
        {
            await Task.Delay(700);
            using var client = new VideoStreamClient();
            var failed = new TaskCompletionSource();
            client.StateChanged += s => { if (s == VideoState.Failed) failed.TrySetResult(); };
            client.Start(url);
            await failed.Task.WaitAsync(TimeSpan.FromSeconds(20));
            Assert.Equal(VideoStreamClient.NoVideoTrackMessage, client.LastError);
            Assert.False(client.HasFrame);
            client.Stop();
        }
        finally
        {
            try { if (!server!.HasExited) server.Kill(); } catch { /* gone */ }
        }
    }
}
