using System.ComponentModel;
using System.Text.Json;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// A scripted UniFi Protect console on top of <see cref="ScriptedController"/>:
/// the Integration API camera list, the classic login (CSRF token + TOKEN
/// cookie, numbered per login so tests can tell sessions apart), the classic
/// camera list with feature flags, and PTZ moves. <see cref="Override"/> takes
/// precedence for the requests a test wants to answer differently.
/// </summary>
internal sealed class FakeProtectConsole : IAsyncDisposable
{
    public const string IntegrationCameras = "GET /proxy/protect/integration/v1/cameras";
    public const string Login = "POST /api/auth/login";
    public const string ClassicCameras = "GET /proxy/protect/api/cameras";
    public static string Move(string cameraId) => $"POST /proxy/protect/api/cameras/{cameraId}/move";
    public static string PackageSnapshot(string cameraId) => $"GET /proxy/protect/api/cameras/{cameraId}/package-snapshot";
    public static string CreateStream(string cameraId) => $"POST /proxy/protect/integration/v1/cameras/{cameraId}/rtsps-stream";

    private int _logins;

    public ScriptedController Controller { get; }

    /// <summary>The Integration API's reply (no feature flags).</summary>
    public string IntegrationBody { get; set; } =
        """{"data":[{"id":"cam1","name":"Drive","state":"CONNECTED"},{"id":"cam2","name":"Yard","state":"CONNECTED"},{"id":"cam3","name":"Door","state":"CONNECTED"}]}""";

    /// <summary>The classic API's camera list: cam1 pans/tilts, cam2 has an optical zoom, cam3 is fixed.</summary>
    public string ClassicBody { get; set; } =
        """[{"id":"cam1","name":"Drive","featureFlags":{"isPtz":true}},{"id":"cam2","name":"Yard","featureFlags":{"canOpticalZoom":true}},{"id":"cam3","name":"Door","featureFlags":{}}]""";

    /// <summary>Answers a request instead of the default script, or returns null to fall through.</summary>
    public Func<FakeRequest, FakeResponse?>? Override { get; set; }

    public FakeProtectConsole()
    {
        Controller = new ScriptedController(Answer);
    }

    public string Address => Controller.Address;

    /// <summary>A successful login answer carrying session <paramref name="n"/>.</summary>
    public static FakeResponse LoginOk(int n) => new(200, "{}", Headers: new[]
    {
        ("X-CSRF-Token", $"csrf-{n}"),
        ("Set-Cookie", $"TOKEN=tok-{n}; path=/; samesite=strict; secure; httponly"),
    });

    private FakeResponse Answer(FakeRequest request)
    {
        if (Override?.Invoke(request) is { } custom) return custom;
        return request.Route switch
        {
            IntegrationCameras => FakeResponse.Json(IntegrationBody),
            Login => LoginOk(Interlocked.Increment(ref _logins)),
            ClassicCameras => FakeResponse.Json(ClassicBody),
            _ when request.Method == "POST" && request.Path.EndsWith("/move", StringComparison.Ordinal) => FakeResponse.Json("{}"),
            _ => FakeResponse.NotFound,
        };
    }

    /// <summary>A service for this console's first site with the given classic-API account.</summary>
    public (ProtectService Service, ControllerSite Site) NewService(string username = "ptz", string password = "secret")
    {
        var site = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore()).Sites[0];
        site.IpAddress = Address;
        site.ApiKey = "test-api-key";
        site.Username = username;
        site.Password = password;
        // Empty trust store: the fake's self-signed key is pinned on first use.
        return (new ProtectService(site, new CertificateTrust(new InMemoryPreferences())), site);
    }

    /// <summary>The continuous-move velocities a PTZ request carried.</summary>
    public static (int X, int Y, int Z) Velocities(FakeRequest move)
    {
        using var doc = JsonDocument.Parse(move.Body);
        Assert.Equal("continuous", doc.RootElement.GetProperty("type").GetString());
        var p = doc.RootElement.GetProperty("payload");
        return (p.GetProperty("x").GetInt32(), p.GetProperty("y").GetInt32(), p.GetProperty("z").GetInt32());
    }

    /// <summary>Completes once <paramref name="condition"/> holds after a property change (or already holds).</summary>
    public static async Task WaitUntil(INotifyPropertyChanged source, Func<bool> condition, int timeoutMs = 10_000)
    {
        var met = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        PropertyChangedEventHandler handler = (_, _) => { if (condition()) met.TrySetResult(); };
        source.PropertyChanged += handler;
        try
        {
            if (condition()) return;
            await met.Task.WaitAsync(TimeSpan.FromMilliseconds(timeoutMs));
        }
        finally
        {
            source.PropertyChanged -= handler;
        }
    }

    public ValueTask DisposeAsync() => Controller.DisposeAsync();
}
