using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;

namespace QuickProtect.Core.Services;

/// <summary>
/// Loopback TLS bridge that lets the FFmpeg engine play UniFi <c>rtsps://</c>
/// streams while the certificate policy stays in managed code.
///
/// FFmpeg would happily speak TLS itself, but then the controller's self-signed
/// certificate would have to be trusted by hand-feeding OpenSSL options — and
/// the trust-on-first-use pinning shared with the HTTPS API would be bypassed.
/// Instead a listener on 127.0.0.1 accepts plain TCP from the in-process demuxer
/// and pipes the bytes over an <see cref="SslStream"/> to the controller,
/// validating the server certificate with the same <see cref="CertificateTrust"/>
/// policy (system trust first, then TOFU pinning keyed by the configured
/// controller identity). <see cref="MapUrl"/> rewrites
/// <c>rtsps://host:7441/token</c> → <c>rtsp://127.0.0.1:{port}/token</c>.
///
/// RTSP's interleaved-TCP mode (the app always forces <c>:rtsp-tcp</c>) keeps
/// all control and media bytes on this single connection, so a dumb byte pump
/// is sufficient — no RTSP awareness needed.
///
/// The listener is reachable by any local process, so it is deliberately
/// limited: loopback only, an ephemeral port, and at most
/// <see cref="MaxConnectionsPerTarget"/> concurrent connections per controller
/// (the app itself needs one per active stream). A stray local client still
/// needs a valid stream token to receive anything.
/// </summary>
public sealed class RtspTlsTunnel : IDisposable
{
    /// <summary>Concurrent tunneled connections allowed per controller endpoint.</summary>
    public const int MaxConnectionsPerTarget = 16;

    private sealed class Mapping
    {
        public required TcpListener Listener { get; init; }
        public int Active;
    }

    private readonly CertificateTrust _trust;
    private readonly Func<string, string> _pinKeyFor;
    private readonly Dictionary<(string Host, int Port), Mapping> _mappings = new();
    private readonly object _lock = new();
    private readonly CancellationTokenSource _cts = new();
    private volatile bool _disposed;

    /// <param name="trust">The shared certificate policy.</param>
    /// <param name="pinKeyFor">
    /// Maps the host a stream URL names to the identity the pin is stored under
    /// (the configured controller, see <c>ControllerAddress.PinKey</c>), so the
    /// video channel and the HTTPS API consult one pin. Defaults to the URL host.
    /// </param>
    public RtspTlsTunnel(CertificateTrust trust, Func<string, string>? pinKeyFor = null)
    {
        _trust = trust;
        _pinKeyFor = pinKeyFor ?? (host => host);
    }

    /// <summary>
    /// Rewrites an <c>rtsps://</c> URL to a plain <c>rtsp://</c> URL served by the
    /// local tunnel. Any other scheme passes through unchanged. Idempotent per
    /// target host:port — repeated calls reuse one listener.
    /// </summary>
    public string MapUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || !uri.Scheme.Equals("rtsps", StringComparison.OrdinalIgnoreCase))
            return url;

        var targetPort = uri.IsDefaultPort ? 322 : uri.Port; // rtsps default per IANA
        // IdnHost strips IPv6 brackets, which the socket connect needs gone.
        var localPort = EnsureListener(uri.IdnHost, targetPort);
        return $"rtsp://127.0.0.1:{localPort}{uri.PathAndQuery}";
    }

    private int EnsureListener(string host, int port)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_mappings.TryGetValue((host, port), out var existing))
                return ((IPEndPoint)existing.Listener.LocalEndpoint).Port;

            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var mapping = new Mapping { Listener = listener };
            _mappings[(host, port)] = mapping;
            _ = AcceptLoopAsync(mapping, host, port, _cts.Token);
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
    }

    private async Task AcceptLoopAsync(Mapping mapping, string host, int port, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var client = await mapping.Listener.AcceptTcpClientAsync(ct);
                if (Interlocked.Increment(ref mapping.Active) > MaxConnectionsPerTarget)
                {
                    Interlocked.Decrement(ref mapping.Active);
                    Log.Line($"[Tunnel] refusing connection for {host}:{port}: limit of {MaxConnectionsPerTarget} reached");
                    client.Dispose();
                    continue;
                }
                _ = Task.Run(() => ServeAsync(client, mapping, host, port, ct), ct);
            }
        }
        catch (OperationCanceledException) { /* shutting down */ }
        catch (ObjectDisposedException) { /* listener stopped */ }
        catch (Exception ex) { Log.Line($"[Tunnel] accept loop ended for {host}:{port}: {ex.Message}"); }
    }

    /// <summary>
    /// Socket and pump buffer size. RTSP-interleaved media arrives as a dense
    /// stream of small TCP segments; generous buffers let each blocking read
    /// drain more per wakeup instead of waking per segment.
    /// </summary>
    private const int PumpBufferSize = 256 * 1024;

    /// <summary>
    /// One tunneled connection: local plain TCP ⇄ TLS to the controller.
    /// After the TLS handshake the byte pumps run on two dedicated blocking
    /// threads rather than async thread-pool continuations: at media packet
    /// rates the per-read dispatch of the async machinery dominated the
    /// keep-alive CPU cost (measured ~30% of a core for 6 idle-but-connected
    /// streams), while a blocking read costs only the wakeup itself.
    /// </summary>
    private async Task ServeAsync(TcpClient client, Mapping mapping, string host, int port, CancellationToken ct)
    {
        var local = client;
        var upstream = new TcpClient();
        SslStream? tls = null;
        var released = 0;
        void Release()
        {
            if (Interlocked.Exchange(ref released, 1) == 0) Interlocked.Decrement(ref mapping.Active);
        }
        try
        {
            local.NoDelay = true;
            local.ReceiveBufferSize = PumpBufferSize;
            local.SendBufferSize = PumpBufferSize;
            await upstream.ConnectAsync(host, port, ct);
            upstream.NoDelay = true;
            upstream.ReceiveBufferSize = PumpBufferSize;
            upstream.SendBufferSize = PumpBufferSize;

            var pinKey = _pinKeyFor(host);
            tls = new SslStream(upstream.GetStream(), leaveInnerStreamOpen: false,
                (_, cert, _, errors) => cert != null && _trust.Evaluate(pinKey, ToX509v2(cert), errors));
            await tls.AuthenticateAsClientAsync(
                new SslClientAuthenticationOptions
                {
                    TargetHost = host,
                    EnabledSslProtocols = System.Security.Authentication.SslProtocols.Tls12
                                          | System.Security.Authentication.SslProtocols.Tls13
                }, ct);
        }
        catch (OperationCanceledException)
        {
            tls?.Dispose();
            local.Dispose();
            upstream.Dispose();
            Release();
            return;
        }
        catch (Exception ex)
        {
            Log.Line($"[Tunnel] connection to {host}:{port} failed: {ex.Message}");
            tls?.Dispose();
            local.Dispose();
            upstream.Dispose();
            Release();
            return;
        }

        // Both pumps share one idempotent cleanup: whichever direction ends
        // first (EOF, reset, or tunnel disposal) closes both sockets, which
        // unblocks the peer thread's read. A reset from the controller is
        // normal when a stream allocation is released.
        var localStream = local.GetStream();
        var cleanedUp = 0;
        CancellationTokenRegistration reg = default;
        void Cleanup()
        {
            if (Interlocked.Exchange(ref cleanedUp, 1) == 1) return;
            try { tls!.Dispose(); } catch { /* already torn down */ }
            try { local.Dispose(); } catch { /* already torn down */ }
            try { upstream.Dispose(); } catch { /* already torn down */ }
            reg.Dispose();
            Release();
        }
        try
        {
            reg = ct.Register(Cleanup);
        }
        catch (ObjectDisposedException)
        {
            // Disposed between the handshake and here: nothing to serve.
            Cleanup();
            return;
        }
        StartPump("QP-Tunnel-up", localStream, tls, Cleanup);
        StartPump("QP-Tunnel-down", tls, localStream, Cleanup);
    }

    private static void StartPump(string name, Stream from, Stream to, Action onDone)
    {
        var thread = new Thread(() =>
        {
            var buf = new byte[PumpBufferSize];
            try
            {
                int n;
                while ((n = from.Read(buf, 0, buf.Length)) > 0)
                    to.Write(buf, 0, n);
            }
            catch { /* connection torn down — expected on either side closing */ }
            finally { onDone(); }
        })
        { IsBackground = true, Name = name };
        thread.Start();
    }

    private static X509Certificate2 ToX509v2(X509Certificate cert)
        => cert as X509Certificate2 ?? new X509Certificate2(cert);

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            _cts.Cancel();
            foreach (var m in _mappings.Values) m.Listener.Stop();
            _mappings.Clear();
        }
        // Not disposing the CTS: pumps still registering their cleanup must be
        // able to observe the cancellation instead of an ObjectDisposedException.
    }
}
