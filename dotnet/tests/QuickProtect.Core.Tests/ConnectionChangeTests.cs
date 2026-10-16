using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Changing the controller address drops the previous controller's camera
/// list, so its cameras never sit under the new address's result.
/// </summary>
public class ConnectionChangeTests
{
    private const string OneCamera = """{"data":[{"id":"cam1","name":"Front","state":"CONNECTED"}]}""";

    /// <summary>
    /// A minimal HTTPS "controller" answering every request with <paramref name="body"/>
    /// (or a camera's web server, given a status and an HTML page).
    /// </summary>
    private sealed class FakeController : IAsyncDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly X509Certificate2 _cert = MakeSelfSigned();
        private readonly CancellationTokenSource _stop = new();
        private readonly Task _loop;

        private readonly string _status;
        private readonly string _contentType;

        public FakeController(string body, string status = "200 OK", string contentType = "application/json")
        {
            _status = status;
            _contentType = contentType;
            _listener.Start();
            _loop = Task.Run(() => ServeAsync(body));
        }

        public string Address => $"127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";

        private async Task ServeAsync(string body)
        {
            while (!_stop.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
                catch (OperationCanceledException) { return; }
                _ = Task.Run(() => AnswerAsync(client, body));
            }
        }

        private async Task AnswerAsync(TcpClient client, string body)
        {
            using var owned = client;
            using var tls = new SslStream(client.GetStream());
            await tls.AuthenticateAsServerAsync(_cert);
            // Read the request head; the camera-list GET has no body.
            var head = new StringBuilder();
            var buffer = new byte[1024];
            while (!head.ToString().Contains("\r\n\r\n"))
            {
                var n = await tls.ReadAsync(buffer);
                if (n == 0) return;
                head.Append(Encoding.ASCII.GetString(buffer, 0, n));
            }
            var payload = Encoding.UTF8.GetBytes(body);
            var response = $"HTTP/1.1 {_status}\r\nContent-Type: {_contentType}\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n";
            await tls.WriteAsync(Encoding.ASCII.GetBytes(response));
            await tls.WriteAsync(payload);
            await tls.FlushAsync();
        }

        public async ValueTask DisposeAsync()
        {
            _stop.Cancel();
            _listener.Stop();
            await _loop;
            _cert.Dispose();
            _stop.Dispose();
        }

        private static X509Certificate2 MakeSelfSigned()
        {
            using var rsa = RSA.Create(2048);
            var req = new CertificateRequest("CN=127.0.0.1", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
            return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx), null);
        }
    }

    private static (ProtectService Service, AppSettings Settings) NewService(string address)
    {
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore())
        {
            IpAddress = address,
            ApiKey = "test-api-key"
        };
        // Empty trust store: the fake controller's key is pinned on first use.
        return (new ProtectService(settings, new CertificateTrust(new InMemoryPreferences())), settings);
    }

    private static int ClosedPort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }

    private const string CameraErrorPage =
        """<?xml version="1.0" encoding="iso-8859-1"?><html><title>404 Not Found</title></html>""";

    [Theory]
    [InlineData("404 Not Found")]
    [InlineData("200 OK")]
    public async Task A_camera_web_server_asks_for_the_console_address(string status)
    {
        await using var camera = new FakeController(CameraErrorPage, status, "text/html");
        var (service, _) = NewService(camera.Address);
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);
        Assert.Equal(ControllerErrors.NotAConsole, service.ErrorMessage);
    }

    [Fact]
    public async Task A_new_address_drops_the_old_controllers_cameras()
    {
        await using var controller = new FakeController(OneCamera);
        var (service, settings) = NewService(controller.Address);
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);
        Assert.Null(service.ErrorMessage);
        Assert.Equal("cam1", Assert.Single(service.Cameras).Id);

        settings.IpAddress = $"127.0.0.1:{ClosedPort()}";
        await service.RefetchForNewConnectionAsync();

        Assert.Empty(service.Cameras);
        Assert.Equal(ControllerErrors.ConnectionRefused, service.ErrorMessage);
    }

    [Fact]
    public async Task The_same_connection_keeps_its_cameras_while_refetching()
    {
        await using var controller = new FakeController(OneCamera);
        var (service, _) = NewService(controller.Address);
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);

        var cleared = false;
        service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProtectService.Cameras) && service.Cameras.Count == 0) cleared = true;
        };
        // e.g. Settings re-applying the unchanged address: nothing to drop.
        await service.RefetchForNewConnectionAsync();

        Assert.False(cleared);
        Assert.Single(service.Cameras);
    }
}
