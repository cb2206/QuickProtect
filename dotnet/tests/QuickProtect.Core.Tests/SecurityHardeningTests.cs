using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

public class CertificateTrustPolicyTests
{
    private static CertificateTrust New() => new(new InMemoryPreferences());

    private static X509Certificate2 SelfSigned(string cn = "CN=test")
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest(cn, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
    }

    [Fact]
    public void System_trusted_certificate_is_accepted_without_pinning()
    {
        var t = New();
        using var cert = SelfSigned();
        Assert.True(t.Evaluate("h", cert, SslPolicyErrors.None));
        Assert.Null(t.Pinned("h"));
    }

    [Fact]
    public void Untrusted_certificate_falls_back_to_tofu_pinning()
    {
        var t = New();
        using var cert = SelfSigned();
        Assert.True(t.Evaluate("h", cert, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.Equal(CertificateTrust.Fingerprint(cert), t.Pinned("h"));
        using var other = SelfSigned();
        Assert.False(t.Evaluate("h", other, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.Equal(CertificateTrust.Fingerprint(other), t.Pending("h"));
    }

    [Fact]
    public void Rejected_event_fires_on_mismatch_only()
    {
        var t = New();
        var rejected = new List<string>();
        t.Rejected += h => rejected.Add(h);
        t.Evaluate("h", "A");
        t.Evaluate("h", "A");
        Assert.Empty(rejected);
        t.Evaluate("h", "B");
        Assert.Equal(new[] { "h" }, rejected);
    }

    [Fact]
    public void All_pending_lists_every_host_sorted()
    {
        var t = New();
        t.Evaluate("b.local", "A");
        t.Evaluate("a.local", "A");
        t.Evaluate("b.local", "B");
        t.Evaluate("a.local", "C");
        var pending = t.AllPending();
        Assert.Equal(new[] { "a.local", "b.local" }, pending.Select(p => p.Host));
        Assert.Equal(new[] { "C", "B" }, pending.Select(p => p.Fingerprint));
        t.TrustPending("a.local");
        Assert.Single(t.AllPending());
    }

    [Fact]
    public void Display_fingerprint_groups_bytes()
    {
        Assert.Equal("ab:cd:ef", CertificateTrust.DisplayFingerprint("abcdef"));
        Assert.Equal("", CertificateTrust.DisplayFingerprint(""));
    }

    [Fact]
    public void Fingerprint_is_spki_sha256()
    {
        using var cert = SelfSigned();
        var expected = Convert.ToHexString(SHA256.HashData(cert.PublicKey.ExportSubjectPublicKeyInfo())).ToLowerInvariant();
        Assert.Equal(expected, CertificateTrust.Fingerprint(cert));
    }
}

public class LogRedactionTests
{
    [Fact]
    public void Stream_token_never_appears()
    {
        var redacted = Log.RedactUrl("rtsps://10.0.1.1:7441/SECRETTOKEN?enableSrtp");
        Assert.DoesNotContain("SECRETTOKEN", redacted);
        Assert.Equal("rtsps://10.0.1.1:7441/…", redacted);
        Assert.Equal("nil", Log.RedactUrl(null));
        Assert.Equal("<unparseable url>", Log.RedactUrl("not a url"));
    }
}

public class UpdateCheckerUrlTests
{
    [Theory]
    [InlineData("https://github.com/cb2206/QuickProtect/releases/tag/v1.4", true)]
    [InlineData("https://GitHub.com/cb2206/QuickProtect/releases/latest", true)]
    [InlineData("http://github.com/cb2206/QuickProtect/releases/tag/v1.4", false)]
    [InlineData("https://github.com/someone-else/QuickProtect/releases", false)]
    [InlineData("https://evil.example/cb2206/QuickProtect/", false)]
    [InlineData("file:///etc/passwd", false)]
    [InlineData(null, false)]
    public void Only_this_projects_release_pages_are_opened(string? url, bool ok)
        => Assert.Equal(ok, UpdateChecker.IsProjectReleaseUrl(url));
}

public class FileSecretStoreTests
{
    [Fact]
    public void Secrets_round_trip_and_file_is_owner_only()
    {
        var dir = Path.Combine(Path.GetTempPath(), "qp-secrets-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "secrets.json");
            var store = new FileSecretStore(path);
            store.Set("apiKey", "s3cret");
            Assert.Equal("s3cret", store.Get("apiKey"));
            Assert.Equal("s3cret", new FileSecretStore(path).Get("apiKey"));
            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(path));
                Assert.False(File.Exists(path + ".tmp"));
            }
            store.Remove("apiKey");
            Assert.Null(store.Get("apiKey"));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}

public class RtspTlsTunnelLimitTests
{
    [Fact]
    public async Task Connections_beyond_the_per_target_cap_are_closed()
    {
        // A TLS server that accepts and then just holds each connection open,
        // so tunnelled clients stay counted against the cap.
        using var cert = MakeSelfSigned();
        var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        var serverPort = ((IPEndPoint)server.LocalEndpoint).Port;
        var held = new List<IDisposable>();
        var serverTask = Task.Run(async () =>
        {
            for (var i = 0; i < RtspTlsTunnel.MaxConnectionsPerTarget; i++)
            {
                var client = await server.AcceptTcpClientAsync();
                var tls = new SslStream(client.GetStream());
                await tls.AuthenticateAsServerAsync(cert);
                held.Add(tls);
                held.Add(client);
            }
        });

        using var tunnel = new RtspTlsTunnel(new CertificateTrust(new InMemoryPreferences()));
        var mapped = new Uri(tunnel.MapUrl($"rtsps://127.0.0.1:{serverPort}/x"));
        var probes = new List<TcpClient>();
        try
        {
            for (var i = 0; i < RtspTlsTunnel.MaxConnectionsPerTarget; i++)
            {
                var p = new TcpClient();
                await p.ConnectAsync(IPAddress.Loopback, mapped.Port);
                probes.Add(p);
            }
            await serverTask.WaitAsync(TimeSpan.FromSeconds(15));

            // One more must be refused: the tunnel closes it without ever
            // opening an upstream connection.
            using var extra = new TcpClient();
            await extra.ConnectAsync(IPAddress.Loopback, mapped.Port);
            var n = await extra.GetStream().ReadAsync(new byte[16]).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(0, n);
        }
        finally
        {
            foreach (var p in probes) p.Dispose();
            foreach (var h in held) h.Dispose();
            server.Stop();
        }
    }

    private static X509Certificate2 MakeSelfSigned()
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=127.0.0.1", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        return new X509Certificate2(cert.Export(X509ContentType.Pfx));
    }
}
