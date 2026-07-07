using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;

namespace QuickProtect.Core.Services;

/// <summary>
/// Loopback TLS tunnel that lets libVLC play UniFi <c>rtsps://</c> streams.
///
/// VLC 3.x has no access module for the <c>rtsps</c> scheme at all (its live555
/// plugin only registers <c>rtsp</c>), so handing it a controller URL fails with
/// "unable to open the MRL". The macOS app solves this with a hand-written
/// RTSP-over-TLS client; this port keeps libVLC for decode/render and instead
/// bridges the transport: a listener on 127.0.0.1 accepts plain TCP from libVLC
/// and pipes the bytes over TLS to the controller, validating the server
/// certificate with the same TOFU <see cref="CertificateTrust"/> policy the
/// HTTPS API uses. <see cref="MapUrl"/> rewrites
/// <c>rtsps://host:7441/token</c> → <c>rtsp://127.0.0.1:{port}/token</c>.
///
/// RTSP's interleaved-TCP mode (the app always forces <c>:rtsp-tcp</c>) keeps
/// all control and media bytes on this single connection, so a dumb byte pump
/// is sufficient — no RTSP awareness needed.
/// </summary>
public sealed class RtspTlsTunnel : IDisposable
{
    private readonly CertificateTrust _trust;
    private readonly Dictionary<(string Host, int Port), TcpListener> _listeners = new();
    private readonly object _lock = new();
    private readonly CancellationTokenSource _cts = new();

    public RtspTlsTunnel(CertificateTrust trust) => _trust = trust;

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
        var localPort = EnsureListener(uri.Host, targetPort);
        return $"rtsp://127.0.0.1:{localPort}{uri.PathAndQuery}";
    }

    private int EnsureListener(string host, int port)
    {
        lock (_lock)
        {
            if (_listeners.TryGetValue((host, port), out var existing))
                return ((IPEndPoint)existing.LocalEndpoint).Port;

            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            _listeners[(host, port)] = listener;
            _ = AcceptLoopAsync(listener, host, port, _cts.Token);
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, string host, int port, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(ct);
                _ = Task.Run(() => ServeAsync(client, host, port, ct), ct);
            }
        }
        catch (OperationCanceledException) { /* shutting down */ }
        catch (ObjectDisposedException) { /* listener stopped */ }
        catch (Exception ex) { Log.Line($"[Tunnel] accept loop ended for {host}:{port}: {ex.Message}"); }
    }

    /// <summary>One tunneled connection: local plain TCP ⇄ TLS to the controller.</summary>
    private async Task ServeAsync(TcpClient client, string host, int port, CancellationToken ct)
    {
        using var local = client;
        using var upstream = new TcpClient();
        try
        {
            local.NoDelay = true;
            await upstream.ConnectAsync(host, port, ct);
            upstream.NoDelay = true;

            await using var tls = new SslStream(upstream.GetStream(), leaveInnerStreamOpen: false,
                (_, cert, _, _) => cert != null && _trust.Evaluate(host, ToX509v2(cert)));
            await tls.AuthenticateAsClientAsync(
                new SslClientAuthenticationOptions { TargetHost = host }, ct);

            var localStream = local.GetStream();
            // Pump both directions; when either side closes, tear down the pair.
            var up = localStream.CopyToAsync(tls, ct);
            var down = tls.CopyToAsync(localStream, ct);
            await Task.WhenAny(up, down);
        }
        catch (OperationCanceledException) { /* shutting down */ }
        catch (Exception ex)
        {
            Log.Line($"[Tunnel] connection to {host}:{port} failed: {ex.Message}");
        }
    }

    private static X509Certificate2 ToX509v2(X509Certificate cert)
        => cert as X509Certificate2 ?? new X509Certificate2(cert);

    public void Dispose()
    {
        _cts.Cancel();
        lock (_lock)
        {
            foreach (var l in _listeners.Values) l.Stop();
            _listeners.Clear();
        }
        _cts.Dispose();
    }
}
