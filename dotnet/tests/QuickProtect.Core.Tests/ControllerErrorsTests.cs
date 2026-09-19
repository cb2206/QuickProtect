using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Failed controller requests become catalog messages (translatable), not the
/// English-only .NET exception text.
/// </summary>
public class ControllerErrorsTests
{
    private static HttpRequestException Wrapping(Exception inner) => new("request failed", inner);

    private static SocketException Socket(SocketError code) => new((int)code);

    [Theory]
    [InlineData(SocketError.HostNotFound, ControllerErrors.HostNotFound)]
    [InlineData(SocketError.NoData, ControllerErrors.HostNotFound)]
    [InlineData(SocketError.TryAgain, ControllerErrors.HostNotFound)]
    [InlineData(SocketError.ConnectionRefused, ControllerErrors.ConnectionRefused)]
    [InlineData(SocketError.TimedOut, ControllerErrors.TimedOut)]
    [InlineData(SocketError.HostUnreachable, ControllerErrors.Unreachable)]
    [InlineData(SocketError.NetworkUnreachable, ControllerErrors.Unreachable)]
    public void Socket_failures_map_by_error_code(SocketError code, string expected)
        => Assert.Equal(expected, ControllerErrors.Describe(Wrapping(Socket(code))));

    [Theory]
    [InlineData(401, ControllerErrors.ApiKeyRejected)]
    [InlineData(403, ControllerErrors.ApiKeyRejected)]
    [InlineData(429, ControllerErrors.Busy)]
    [InlineData(500, ControllerErrors.ServerError)]
    [InlineData(503, ControllerErrors.ServerError)]
    [InlineData(404, ControllerErrors.UnexpectedResponse)]
    public void Http_statuses_map_to_messages(int status, string expected)
        => Assert.Equal(expected, ControllerErrors.Describe(new ProtectService.ApiException(status, "body")));

    [Fact]
    public void Other_failures_map_to_messages()
    {
        Assert.Equal(ControllerErrors.SecureConnectionFailed,
            ControllerErrors.Describe(Wrapping(new AuthenticationException("tls"))));
        Assert.Equal(ControllerErrors.TimedOut, ControllerErrors.Describe(new TaskCanceledException()));
        Assert.Equal(ControllerErrors.UnreadableResponse, ControllerErrors.Describe(new JsonException()));
        Assert.Equal(ControllerErrors.InvalidAddress, ControllerErrors.Describe(new UriFormatException()));
        Assert.Equal(ControllerErrors.Unreachable, ControllerErrors.Describe(new HttpRequestException("?")));
    }

    [Fact]
    public void Unknown_failures_keep_their_own_message()
        => Assert.Equal("something else", ControllerErrors.Describe(new InvalidOperationException("something else")));

    private static (ProtectService Service, AppSettings Settings) NewService(string address)
    {
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore())
        {
            IpAddress = address,
            ApiKey = "test-api-key"
        };
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

    [Fact]
    public async Task Refused_connection_reports_the_catalog_message()
    {
        var (service, _) = NewService($"127.0.0.1:{ClosedPort()}");
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);
        Assert.Equal(ControllerErrors.ConnectionRefused, service.ErrorMessage);
    }

    [Fact]
    public async Task Changing_the_address_replaces_the_old_error()
    {
        var (service, settings) = NewService($"127.0.0.1:{ClosedPort()}");
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);
        Assert.Equal(ControllerErrors.ConnectionRefused, service.ErrorMessage);

        settings.IpAddress = "";
        await service.RefetchForNewConnectionAsync();

        Assert.Equal("No IP address configured. Open Settings.", service.ErrorMessage);
    }

    [Fact]
    public async Task A_fetch_hanging_on_the_old_address_does_not_block_the_new_one()
    {
        // Accepts the TCP connection and never answers the TLS handshake.
        var silent = new TcpListener(IPAddress.Loopback, 0);
        silent.Start();
        var accepted = silent.AcceptTcpClientAsync();
        try
        {
            var (service, settings) = NewService($"127.0.0.1:{((IPEndPoint)silent.LocalEndpoint).Port}");
            using var disposeService = service;
            var hanging = service.FetchCamerasAsync(forced: true);
            using (await accepted) // the old fetch is now stuck in the handshake
            {
                settings.IpAddress = "";
                var refetch = service.RefetchForNewConnectionAsync();

                // Without cancelling the stale fetch this would wait out the 15 s HTTP timeout.
                Assert.Same(refetch, await Task.WhenAny(refetch, Task.Delay(TimeSpan.FromSeconds(5))));
                await refetch;
                Assert.True(hanging.IsCompleted);
                Assert.Equal("No IP address configured. Open Settings.", service.ErrorMessage);
            }
        }
        finally
        {
            silent.Stop();
        }
    }
}
