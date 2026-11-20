using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace QuickProtect.Core.Tests;

/// <summary>One request as the fake controller received it.</summary>
internal sealed record FakeRequest(string Method, string Path, IReadOnlyDictionary<string, string> Headers, string Body)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;

    /// <summary>"POST /api/auth/login" — path without the query string.</summary>
    public string Route => $"{Method} {Path.Split('?', 2)[0]}";
}

/// <summary>What the fake controller answers.</summary>
internal sealed record FakeResponse(int Status, string Body = "", string ContentType = "application/json",
                                    IReadOnlyList<(string Name, string Value)>? Headers = null)
{
    public static FakeResponse Json(string body) => new(200, body);
    public static FakeResponse NotFound => new(404, """{"error":"not found"}""");
}

/// <summary>
/// A local HTTPS "controller" that answers each request from a script
/// (<see cref="Handler"/>, replaceable mid-test) and records every request,
/// including its body — enough to drive both the Integration and the classic
/// API paths of <c>ProtectService</c>. Unlike <c>ConnectionChangeTests.FakeController</c>
/// it routes by method and path.
/// </summary>
internal sealed class ScriptedController : IAsyncDisposable
{
    private static readonly X509Certificate2 Cert = MakeSelfSigned();

    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly Task _loop;
    private readonly object _signalLock = new();
    private TaskCompletionSource _received = NewSignal();

    /// <summary>Every request received so far, in arrival order.</summary>
    public ConcurrentQueue<FakeRequest> Requests { get; } = new();

    /// <summary>The script; requests it doesn't route get a 404.</summary>
    public Func<FakeRequest, FakeResponse> Handler { get; set; } = _ => FakeResponse.NotFound;

    public ScriptedController(Func<FakeRequest, FakeResponse>? handler = null)
    {
        if (handler != null) Handler = handler;
        _listener.Start();
        _loop = Task.Run(ServeAsync);
    }

    public string Address => $"127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";

    /// <summary>Requests to <paramref name="route"/> (e.g. "POST /api/auth/login").</summary>
    public IReadOnlyList<FakeRequest> To(string route) => Requests.Where(r => r.Route == route).ToList();

    /// <summary>Waits until <paramref name="count"/> requests to <paramref name="route"/> have arrived.</summary>
    public async Task<IReadOnlyList<FakeRequest>> WaitFor(string route, int count = 1, int timeoutMs = 10_000)
    {
        using var timeout = new CancellationTokenSource(timeoutMs);
        while (true)
        {
            Task signal;
            lock (_signalLock) signal = _received.Task;
            var matching = To(route);
            if (matching.Count >= count) return matching;
            try
            {
                await signal.WaitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                throw new TimeoutException(
                    $"waited for {count}× {route}; got: {string.Join(", ", Requests.Select(r => r.Route))}");
            }
        }
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private async Task ServeAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch (OperationCanceledException) { return; }
            _ = Task.Run(() => AnswerAsync(client));
        }
    }

    private async Task AnswerAsync(TcpClient client)
    {
        using var owned = client;
        using var tls = new SslStream(client.GetStream());
        await tls.AuthenticateAsServerAsync(Cert);

        var raw = new List<byte>();
        var buffer = new byte[4096];
        int headEnd;
        while ((headEnd = IndexOfHeadEnd(raw)) < 0)
        {
            var n = await tls.ReadAsync(buffer);
            if (n == 0) return;
            raw.AddRange(buffer.AsSpan(0, n).ToArray());
        }
        var headText = Encoding.ASCII.GetString(raw.GetRange(0, headEnd).ToArray());
        var lines = headText.Split("\r\n");
        var requestLine = lines[0].Split(' ');
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        var length = headers.TryGetValue("Content-Length", out var cl) && int.TryParse(cl, out var len) ? len : 0;
        var bodyStart = headEnd + 4;
        while (raw.Count - bodyStart < length)
        {
            var n = await tls.ReadAsync(buffer);
            if (n == 0) break;
            raw.AddRange(buffer.AsSpan(0, n).ToArray());
        }
        var body = Encoding.UTF8.GetString(raw.Skip(bodyStart).Take(length).ToArray());
        var request = new FakeRequest(requestLine[0], requestLine[1], headers, body);

        // Answer before recording: a test woken by the request must find the
        // reply already decided (and the client unblocked soon after).
        var response = Handler(request);
        Requests.Enqueue(request);
        lock (_signalLock)
        {
            _received.TrySetResult();
            _received = NewSignal();
        }

        var payload = Encoding.UTF8.GetBytes(response.Body);
        var head = new StringBuilder()
            .Append($"HTTP/1.1 {response.Status} Scripted\r\n")
            .Append($"Content-Type: {response.ContentType}\r\n")
            .Append($"Content-Length: {payload.Length}\r\n")
            .Append("Connection: close\r\n");
        foreach (var (name, value) in response.Headers ?? Array.Empty<(string, string)>())
            head.Append($"{name}: {value}\r\n");
        head.Append("\r\n");
        await tls.WriteAsync(Encoding.ASCII.GetBytes(head.ToString()));
        await tls.WriteAsync(payload);
        await tls.FlushAsync();
    }

    private static int IndexOfHeadEnd(List<byte> raw)
    {
        for (var i = 0; i + 3 < raw.Count; i++)
            if (raw[i] == '\r' && raw[i + 1] == '\n' && raw[i + 2] == '\r' && raw[i + 3] == '\n')
                return i;
        return -1;
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _listener.Stop();
        await _loop;
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
