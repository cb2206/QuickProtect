using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// The "controller certificate changed" state: derived from the pin store, so
/// the panel shows the real cause no matter which request hit the rejection.
/// </summary>
public class CertificateChangeTests
{
    [Fact]
    public void Change_reports_trusted_and_new_key()
    {
        var t = new CertificateTrust(new InMemoryPreferences());
        Assert.Null(t.Change("h"));
        t.Evaluate("h", "aa");
        Assert.Null(t.Change("h"));
        t.Evaluate("h", "bb");
        Assert.Equal(new CertificateChange("h", "aa", "bb"), t.Change("h"));
    }

    [Fact]
    public void Changed_fires_on_real_changes_only()
    {
        var t = new CertificateTrust(new InMemoryPreferences());
        var fired = 0;
        t.Changed += () => fired++;
        t.Evaluate("h", "aa");   // pin written
        Assert.Equal(1, fired);
        t.Evaluate("h", "aa");   // routine reconnect
        Assert.Equal(1, fired);
        t.Evaluate("h", "bb");   // pending written
        Assert.Equal(2, fired);
        t.Evaluate("h", "bb");   // same candidate again
        Assert.Equal(2, fired);
    }

    [Fact]
    public void Wrapped_fingerprint_splits_after_sixteen_bytes()
    {
        var rows = CertificateTrust.DisplayFingerprint(new string('a', 64), bytesPerLine: 16).Split('\n');
        Assert.Equal(2, rows.Length);
        Assert.All(rows, row => Assert.Equal(16, row.Split(':').Length));
    }

    private static (ProtectService Service, CertificateTrust Trust, AppSettings Settings) NewService(string address)
    {
        var trust = new CertificateTrust(new InMemoryPreferences());
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore())
        {
            IpAddress = address,
            ApiKey = "test-api-key"
        };
        return (new ProtectService(settings, trust), trust, settings);
    }

    [Fact]
    public void Service_follows_the_configured_controller_and_trusting_clears_it()
    {
        var (service, trust, settings) = NewService("10.0.0.1");
        using var disposeService = service;
        var raised = 0;
        service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProtectService.CertificateChange)) raised++;
        };

        trust.Evaluate("10.0.0.5", "aa");
        trust.Evaluate("10.0.0.5", "bb");
        Assert.Null(service.CertificateChange); // another controller's pending key

        settings.IpAddress = "10.0.0.5";
        Assert.Equal(new CertificateChange("10.0.0.5", "aa", "bb"), service.CertificateChange);
        Assert.Equal(1, raised);

        service.TrustPendingCertificate("10.0.0.5");
        Assert.Null(service.CertificateChange);
        Assert.Equal("bb", trust.Pinned("10.0.0.5"));
        Assert.Equal(2, raised);
    }

    /// <summary>
    /// End to end: a controller presenting a key other than the pinned one
    /// shows the certificate message and publishes the change, instead of the
    /// generic TLS failure text.
    /// </summary>
    [Fact]
    public async Task Fetch_against_a_changed_certificate_reports_the_change()
    {
        using var cert = MakeSelfSigned();
        var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        var port = ((IPEndPoint)server.LocalEndpoint).Port;
        // Never awaited: the client aborts the handshake, which faults this task.
        _ = Task.Run(async () =>
        {
            using var client = await server.AcceptTcpClientAsync();
            using var tls = new SslStream(client.GetStream());
            await tls.AuthenticateAsServerAsync(cert);
        });
        try
        {
            var (service, trust, _) = NewService($"127.0.0.1:{port}");
            using var disposeService = service;
            trust.Evaluate("127.0.0.1", "00"); // the key trusted before the change

            await service.FetchCamerasAsync(forced: true);

            Assert.Equal(ProtectService.CertificateChangedMessage, service.ErrorMessage);
            Assert.Equal(CertificateTrust.Fingerprint(cert), service.CertificateChange?.NewFingerprint);
            Assert.Equal("00", service.CertificateChange?.TrustedFingerprint);
        }
        finally
        {
            server.Stop();
        }
    }

    [Fact]
    public async Task Unreachable_controller_without_a_pending_change_reports_the_transport_error()
    {
        // Bind and release a port so nothing listens on it.
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();

        var (service, _, _) = NewService($"127.0.0.1:{port}");
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);

        Assert.Null(service.CertificateChange);
        Assert.NotNull(service.ErrorMessage);
        Assert.NotEqual(ProtectService.CertificateChangedMessage, service.ErrorMessage);
    }

    private static X509Certificate2 MakeSelfSigned()
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest("CN=127.0.0.1", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx), null);
    }
}
