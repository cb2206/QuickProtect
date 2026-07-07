using System.ComponentModel;
using System.Net;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using QuickProtect.Core.Models;

namespace QuickProtect.Core.Services;

/// <summary>
/// Handles all communication with the UniFi Protect controller — a port of the
/// macOS <c>ProtectService</c>.
///
/// Two HTTP paths, mirroring the original:
///  • Integration API (header <c>X-API-Key</c>): list cameras, create/delete
///    on-demand rtsps-stream allocations.
///  • Classic API (cookie auth: TOKEN + X-CSRF-Token): login, PTZ continuous moves,
///    and PTZ capability flags the Integration API doesn't expose.
///
/// Both share trust-on-first-use certificate pinning via <see cref="CertificateTrust"/>.
/// </summary>
public sealed class ProtectService : INotifyPropertyChanged, IDisposable
{
    private readonly AppSettings _settings;
    private readonly CertificateTrust _trust;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private IReadOnlyList<Camera> _cameras = Array.Empty<Camera>();
    public IReadOnlyList<Camera> Cameras { get => _cameras; private set { _cameras = value; Raise(); } }

    private bool _isLoading;
    public bool IsLoading { get => _isLoading; private set { _isLoading = value; Raise(); } }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; private set { _errorMessage = value; Raise(); } }

    private bool _isClassicLoggedIn;
    public bool IsClassicLoggedIn { get => _isClassicLoggedIn; private set { _isClassicLoggedIn = value; Raise(); } }

    /// <summary>Raised on the UI thread by the host when a cert mismatch is detected.</summary>
    public event EventHandler<string>? CertificateChanged;

    // Active server-side allocations "<cameraId>:<quality>". Popover-owned streams
    // are torn down on close; pinned streams live independently.
    private readonly HashSet<string> _activeStreams = new();
    private readonly HashSet<string> _pinnedStreams = new();
    private readonly object _streamLock = new();

    // Classic-API credentials captured at login.
    private readonly object _credLock = new();
    private string? _csrfToken;
    private string? _tokenCookie;

    private readonly HttpClient _integration;
    private readonly HttpClient _classic;
    private readonly CookieContainer _classicCookies = new();

    public ProtectService(AppSettings settings, CertificateTrust trust)
    {
        _settings = settings;
        _trust = trust;

        _integration = new HttpClient(MakeHandler(useCookies: false)) { Timeout = TimeSpan.FromSeconds(15) };
        _classic = new HttpClient(MakeHandler(useCookies: true)) { Timeout = TimeSpan.FromSeconds(15) };
    }

    private HttpClientHandler MakeHandler(bool useCookies)
    {
        var handler = new HttpClientHandler
        {
            UseCookies = useCookies,
            CookieContainer = useCookies ? _classicCookies : new CookieContainer(),
            AllowAutoRedirect = false
        };
        // TOFU pinning — replaces system trust for the self-signed controller cert.
        handler.ServerCertificateCustomValidationCallback = (_, cert, _, _) =>
        {
            if (cert == null) return false;
            var host = _settings.IpAddress;
            var ok = _trust.Evaluate(host, cert);
            if (!ok)
                CertificateChanged?.Invoke(this,
                    "The controller's certificate changed. Open Settings to review and trust it.");
            return ok;
        };
        return handler;
    }

    private string? BaseUrl => string.IsNullOrEmpty(_settings.IpAddress) ? null : $"https://{_settings.IpAddress}";
    private Uri? MakeUrl(string path) => BaseUrl is { } b ? new Uri($"{b}/{path}") : null;

    // MARK: - Fetch camera list

    public async Task FetchCamerasAsync()
    {
        Log.Line("[API] fetchCameras called");
        if (!Validate()) { Log.Line("[API] validate failed"); return; }
        IsLoading = true;

        try
        {
            var url = MakeUrl("proxy/protect/integration/v1/cameras") ?? throw new InvalidOperationException("invalid URL");
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("X-API-Key", _settings.ApiKey);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");

            using var resp = await _integration.SendAsync(req).ConfigureAwait(false);
            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
                throw new ApiException((int)resp.StatusCode, body);

            var cameras = ParseCameraList(body);
            ApplySuccess(cameras);

            if (!string.IsNullOrEmpty(_settings.Username) && !string.IsNullOrEmpty(_settings.Password))
                await EnrichPtzFlagsAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            ApplyError(ex);
        }
    }

    /// <summary>Integration API wraps the array as <c>{ "data": [...] }</c>; classic returns a bare array.</summary>
    private static IReadOnlyList<Camera> ParseCameraList(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        JsonElement arr = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("data", out var data)
            ? data : root;
        if (arr.ValueKind != JsonValueKind.Array) return Array.Empty<Camera>();
        return arr.Deserialize<List<Camera>>() ?? new List<Camera>();
    }

    // MARK: - RTSP stream creation (Integration API)

    /// <summary>
    /// Creates an on-demand RTSP stream, degrading through the remaining quality
    /// tiers if the requested one isn't available. Returns the playable URL and
    /// the quality that actually succeeded, or null if every tier fails.
    /// </summary>
    public Task<(string url, string quality)?> CreateRtspStreamUrlAsync(Camera camera, string quality = "medium")
        => CreateStreamAsync(camera, quality, pinned: false);

    /// <summary>Stream-URL creation for a pinned floating window (tracked separately).</summary>
    public Task<(string url, string quality)?> CreatePinnedStreamUrlAsync(Camera camera, string quality = "high")
        => CreateStreamAsync(camera, quality, pinned: true);

    private async Task<(string url, string quality)?> CreateStreamAsync(Camera camera, string quality, bool pinned)
    {
        foreach (var tier in QualityFallbackLadder(quality))
        {
            var url = await RequestRtspStreamUrlAsync(camera, tier, pinned).ConfigureAwait(false);
            if (url != null)
            {
                if (tier != quality)
                    Log.Line($"[Stream] {quality} unavailable for {camera.Name}; using {tier}");
                return (url, tier);
            }
        }
        return null;
    }

    private static IEnumerable<string> QualityFallbackLadder(string quality) => quality switch
    {
        "high" => new[] { "high", "medium", "low" },
        "medium" => new[] { "medium", "low", "high" },
        "low" => new[] { "low", "medium", "high" },
        _ => new[] { quality } // a distinct lens (e.g. "package") is tried alone
    };

    private async Task<string?> RequestRtspStreamUrlAsync(Camera camera, string quality, bool pinned)
    {
        Log.Line($"[Stream] requestRtspStreamURL({quality}) for {camera.Name}");
        var url = MakeUrl($"proxy/protect/integration/v1/cameras/{camera.Id}/rtsps-stream");
        if (url == null) { Log.Line("[Stream] makeURL failed"); return null; }

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.TryAddWithoutValidation("X-API-Key", _settings.ApiKey);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            req.Content = new StringContent(
                JsonSerializer.Serialize(new { qualities = new[] { quality } }), Encoding.UTF8, "application/json");

            using var resp = await _integration.SendAsync(req).ConfigureAwait(false);
            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (resp.StatusCode != HttpStatusCode.OK)
            {
                Log.Line($"[Stream] HTTP {(int)resp.StatusCode}: {body}");
                return null;
            }

            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty(quality, out var v) || v.ValueKind != JsonValueKind.String)
                return null;

            var key = StreamKey(camera.Id, quality);
            lock (_streamLock) { (pinned ? _pinnedStreams : _activeStreams).Add(key); }
            var playable = ToPlayableUrl(v.GetString()!);
            Log.Line($"[Stream] Created {quality} for {camera.Name}: {playable}");
            return playable;
        }
        catch (Exception ex)
        {
            Log.Line($"[Stream] request failed: {ex.Message}");
            return null;
        }
    }

    private static string StreamKey(string cameraId, string quality) => $"{cameraId}:{quality}";

    // MARK: - RTSP stream cleanup

    public void CleanupStreams()
    {
        string[] keys;
        lock (_streamLock) { keys = _activeStreams.ToArray(); _activeStreams.Clear(); }
        foreach (var key in keys) DeleteByKey(key);
    }

    public void ReleaseStream(string cameraId, string quality)
    {
        var key = StreamKey(cameraId, quality);
        lock (_streamLock) { if (!_activeStreams.Remove(key)) return; }
        DeleteRtspStream(cameraId, quality);
    }

    public void ReleasePinnedStream(string cameraId, string quality)
    {
        var key = StreamKey(cameraId, quality);
        lock (_streamLock) { if (!_pinnedStreams.Remove(key)) return; }
        DeleteRtspStream(cameraId, quality);
    }

    public void CleanupPinnedStreams()
    {
        string[] keys;
        lock (_streamLock) { keys = _pinnedStreams.ToArray(); _pinnedStreams.Clear(); }
        foreach (var key in keys) DeleteByKey(key);
    }

    private void DeleteByKey(string key)
    {
        var parts = key.Split(':', 2);
        if (parts.Length == 2) DeleteRtspStream(parts[0], parts[1]);
    }

    private void DeleteRtspStream(string cameraId, string quality)
    {
        var url = MakeUrl($"proxy/protect/integration/v1/cameras/{cameraId}/rtsps-stream?qualities={quality}");
        if (url == null) return;
        _ = Task.Run(async () =>
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Delete, url);
                req.Headers.TryAddWithoutValidation("X-API-Key", _settings.ApiKey);
                using var _ = await _integration.SendAsync(req).ConfigureAwait(false);
            }
            catch { /* fire and forget */ }
        });
    }

    // MARK: - Classic API (cookie auth — required for PTZ)

    public async Task<bool> ClassicLoginAsync()
    {
        if (string.IsNullOrEmpty(_settings.Username) || string.IsNullOrEmpty(_settings.Password)) return false;
        var url = MakeUrl("api/auth/login");
        if (url == null) return false;

        Log.Line("[PTZ] classicLogin attempting...");
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Content = new StringContent(
                JsonSerializer.Serialize(new { username = _settings.Username, password = _settings.Password }),
                Encoding.UTF8, "application/json");

            using var resp = await _classic.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Line("[PTZ] classicLogin FAILED");
                IsClassicLoggedIn = false;
                SetCreds(null, null);
                return false;
            }

            var csrf = resp.Headers.TryGetValues("X-CSRF-Token", out var vals) ? vals.FirstOrDefault() : null;
            string? token = null;
            foreach (Cookie c in _classicCookies.GetCookies(url))
                if (c.Name == "TOKEN") token = c.Value;
            SetCreds(csrf, token);

            IsClassicLoggedIn = true;
            Log.Line($"[PTZ] classicLogin OK, csrf={csrf != null}, token={token != null}");
            return true;
        }
        catch
        {
            Log.Line("[PTZ] classicLogin FAILED (exception)");
            IsClassicLoggedIn = false;
            SetCreds(null, null);
            return false;
        }
    }

    private void SetCreds(string? csrf, string? token)
    {
        lock (_credLock) { _csrfToken = csrf; _tokenCookie = token; }
    }

    private async Task EnrichPtzFlagsAsync()
    {
        if (!await ClassicLoginAsync().ConfigureAwait(false)) return;
        var url = MakeUrl("proxy/protect/api/cameras");
        if (url == null) return;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            using var resp = await _classic.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return;
            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            var classic = ParseCameraList(body);
            if (classic.Count == 0) return; // don't wipe known flags on a transient empty response

            var ptz = classic.Where(c => c.IsPtz).Select(c => c.Id).ToHashSet();
            var zoom = classic.Where(c => c.CanZoom).Select(c => c.Id).ToHashSet();
            foreach (var cam in _cameras)
            {
                cam.IsPtz = ptz.Contains(cam.Id);
                cam.CanZoom = zoom.Contains(cam.Id);
            }
            Raise(nameof(Cameras));
        }
        catch { /* enrichment is best-effort */ }
    }

    // MARK: - PTZ control (classic API — continuous velocity moves)

    private const double PtzVelocityScale = 1000.0;
    private readonly object _ptzLock = new();
    private (double x, double y, double z) _ptzDesired;
    private Task _ptzChain = Task.CompletedTask;
    private readonly PtzBurstTimer _ptzBurst = new();

    public void PtzSetAxes(string cameraId, double? pan = null, double? tilt = null, double? zoom = null)
    {
        // A quick tap should still produce meaningful travel: when an axis is
        // released early, postpone its stop until the minimum burst is up.
        var delay = _ptzBurst.Update(pan, tilt, zoom, DateTime.UtcNow);
        EnqueuePtz(cameraId, delay, state =>
        {
            if (pan is { } p) state.x = p * PtzVelocityScale;
            if (tilt is { } t) state.y = t * PtzVelocityScale;
            if (zoom is { } z) state.z = z * PtzVelocityScale;
            return state;
        });
    }

    public void PtzStopAll(string cameraId)
    {
        _ptzBurst.Reset();
        EnqueuePtz(cameraId, TimeSpan.Zero, _ => (0, 0, 0));
    }

    private void EnqueuePtz(string cameraId, TimeSpan delay,
                            Func<(double x, double y, double z), (double x, double y, double z)> mutate)
    {
        lock (_ptzLock)
        {
            var previous = _ptzChain;
            _ptzChain = Task.Run(async () =>
            {
                await previous.ConfigureAwait(false);
                if (delay > TimeSpan.Zero) await Task.Delay(delay).ConfigureAwait(false);
                if (!IsClassicLoggedIn && !await ClassicLoginAsync().ConfigureAwait(false))
                {
                    ApplyError(new InvalidOperationException(
                        "PTZ unavailable — check the username and password in Settings."));
                    return;
                }
                (double x, double y, double z) next;
                lock (_ptzLock)
                {
                    next = mutate(_ptzDesired);
                    if (next == _ptzDesired) return;
                    _ptzDesired = next;
                }
                await SendMoveAsync(cameraId, next).ConfigureAwait(false);
            });
        }
    }

    private async Task SendMoveAsync(string cameraId, (double x, double y, double z) v)
    {
        var url = MakeUrl($"proxy/protect/api/cameras/{cameraId}/move");
        if (url == null) return;
        string csrf, token;
        lock (_credLock) { csrf = _csrfToken ?? ""; token = _tokenCookie ?? ""; }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            if (csrf.Length > 0) req.Headers.TryAddWithoutValidation("X-CSRF-Token", csrf);
            var payload = new { type = "continuous", payload = new { x = (int)v.x, y = (int)v.y, z = (int)v.z } };
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");

            using var resp = await _classic.SendAsync(req).ConfigureAwait(false);
            Log.Line($"[PTZ] sendMove HTTP {(int)resp.StatusCode}");
            if (resp.StatusCode == HttpStatusCode.Unauthorized)
            {
                IsClassicLoggedIn = false;
                SetCreds(null, null);
            }
        }
        catch (Exception ex) { Log.Line($"[PTZ] sendMove failed: {ex.Message}"); }
    }

    // MARK: - Helpers

    /// <summary>
    /// Returns the rtsps:// URL with <c>?enableSrtp</c> stripped (the player handles
    /// SRTP via TLS); the session token is only valid on the rtsps endpoint.
    /// </summary>
    private static string ToPlayableUrl(string rtsps)
    {
        var q = rtsps.IndexOf("?enableSrtp", StringComparison.OrdinalIgnoreCase);
        if (q < 0) return rtsps;
        // Strip just that param; keep any others.
        var uri = new UriBuilder(rtsps);
        var kept = uri.Query.TrimStart('?').Split('&')
            .Where(p => !p.StartsWith("enableSrtp", StringComparison.OrdinalIgnoreCase));
        uri.Query = string.Join("&", kept);
        return uri.Uri.ToString();
    }

    private void ApplySuccess(IReadOnlyList<Camera> cameras)
    {
        Log.Line($"[API] applySuccess: {cameras.Count} cameras");
        Cameras = cameras;
        IsLoading = false;
        ErrorMessage = null;
    }

    private void ApplyError(Exception ex)
    {
        Log.Line($"[API] applyError: {ex.Message}");
        ErrorMessage = ex.Message;
        IsLoading = false;
    }

    private bool Validate()
    {
        if (string.IsNullOrEmpty(_settings.IpAddress)) { ErrorMessage = "No IP address configured. Open Settings."; return false; }
        if (string.IsNullOrEmpty(_settings.ApiKey)) { ErrorMessage = "No API key configured. Open Settings."; return false; }
        return true;
    }

    public void Dispose()
    {
        _integration.Dispose();
        _classic.Dispose();
    }

    public sealed class ApiException : Exception
    {
        public int StatusCode { get; }
        public ApiException(int status, string body)
            : base($"HTTP {status} – {(body.Length > 200 ? body[..200] : body)}") => StatusCode = status;
    }
}
