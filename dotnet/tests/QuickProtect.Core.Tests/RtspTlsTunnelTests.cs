using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

public class RtspTlsTunnelTests
{
    private static RtspTlsTunnel MakeTunnel(out CertificateTrust trust)
    {
        trust = new CertificateTrust(new InMemoryPreferences());
        return new RtspTlsTunnel(trust);
    }

    [Fact]
    public void MapUrl_passes_non_rtsps_through()
    {
        using var tunnel = MakeTunnel(out _);
        Assert.Equal("rtsp://10.0.1.1:7447/alias", tunnel.MapUrl("rtsp://10.0.1.1:7447/alias"));
        Assert.Equal("not a url", tunnel.MapUrl("not a url"));
    }

    [Fact]
    public void MapUrl_rewrites_rtsps_to_loopback_and_preserves_path()
    {
        using var tunnel = MakeTunnel(out _);
        var mapped = tunnel.MapUrl("rtsps://10.0.1.1:7441/tokenABC");
        var uri = new Uri(mapped);
        Assert.Equal("rtsp", uri.Scheme);
        Assert.Equal("127.0.0.1", uri.Host);
        Assert.InRange(uri.Port, 1, 65535);
        Assert.Equal("/tokenABC", uri.AbsolutePath);
    }

    [Fact]
    public void MapUrl_reuses_one_listener_per_target()
    {
        using var tunnel = MakeTunnel(out _);
        var a = new Uri(tunnel.MapUrl("rtsps://10.0.1.1:7441/one"));
        var b = new Uri(tunnel.MapUrl("rtsps://10.0.1.1:7441/two"));
        Assert.Equal(a.Port, b.Port);
        var c = new Uri(tunnel.MapUrl("rtsps://10.0.1.2:7441/one"));
        Assert.NotEqual(a.Port, c.Port);
    }

    [Fact]
    public async Task Tunnel_round_trips_bytes_over_tls_and_pins_certificate()
    {
        // Local TLS echo server with a fresh self-signed certificate.
        using var cert = MakeSelfSigned();
        var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        var serverPort = ((IPEndPoint)server.LocalEndpoint).Port;
        var serverTask = Task.Run(async () =>
        {
            using var client = await server.AcceptTcpClientAsync();
            await using var tls = new SslStream(client.GetStream());
            await tls.AuthenticateAsServerAsync(cert);
            var buf = new byte[64];
            var n = await tls.ReadAsync(buf);
            await tls.WriteAsync(buf.AsMemory(0, n)); // echo
            await tls.FlushAsync();
        });

        using var tunnel = MakeTunnel(out var trust);
        var mapped = new Uri(tunnel.MapUrl($"rtsps://127.0.0.1:{serverPort}/x"));

        using var probe = new TcpClient();
        await probe.ConnectAsync(IPAddress.Loopback, mapped.Port);
        var stream = probe.GetStream();
        var payload = Encoding.ASCII.GetBytes("OPTIONS * RTSP/1.0\r\n\r\n");
        await stream.WriteAsync(payload);
        var readBuf = new byte[payload.Length];
        var got = 0;
        while (got < payload.Length)
        {
            var n = await stream.ReadAsync(readBuf.AsMemory(got)).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            Assert.True(n > 0, "tunnel closed before echo completed");
            got += n;
        }
        Assert.Equal(payload, readBuf);
        await serverTask.WaitAsync(TimeSpan.FromSeconds(10));

        // First contact pinned the server's key (TOFU), same as the HTTPS path.
        Assert.Equal(CertificateTrust.Fingerprint(cert), trust.Pinned("127.0.0.1"));
    }

    [Fact]
    public async Task Tunnel_refuses_mismatched_certificate()
    {
        using var cert = MakeSelfSigned();
        var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        var serverPort = ((IPEndPoint)server.LocalEndpoint).Port;
        var serverTask = Task.Run(async () =>
        {
            using var client = await server.AcceptTcpClientAsync();
            await using var tls = new SslStream(client.GetStream());
            try { await tls.AuthenticateAsServerAsync(cert); } catch { /* client aborts on pin mismatch */ }
        });

        using var tunnel = MakeTunnel(out var trust);
        trust.Evaluate("127.0.0.1", "0000000000000000000000000000000000000000000000000000000000000000");
        var mapped = new Uri(tunnel.MapUrl($"rtsps://127.0.0.1:{serverPort}/x"));

        using var probe = new TcpClient();
        await probe.ConnectAsync(IPAddress.Loopback, mapped.Port);
        var stream = probe.GetStream();
        // The tunnel must drop the connection without ever returning data.
        var n = await stream.ReadAsync(new byte[16]).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(0, n);
        await serverTask.WaitAsync(TimeSpan.FromSeconds(10));
    }

    private static X509Certificate2 MakeSelfSigned()
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=127.0.0.1", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        // Re-import so the private key is usable for TLS on Windows.
        return new X509Certificate2(cert.Export(X509ContentType.Pfx));
    }
}
