using System.ComponentModel;
using System.Net;
using System.Net.Http.Json;
using System.Net.Security;
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
public sealed class ProtectService : INotifyPropertyChanged, IDisposable, IStreamAllocator
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

    /// <summary>
    /// Controller reachability / API errors. The panel replaces the grid with an
    /// error card while this is set, so it must only carry problems that make
    /// the camera list itself unusable.
    /// </summary>
    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; private set { _errorMessage = value; Raise(); } }

    /// <summary>
    /// PTZ-only problems (classic-API login), surfaced as a toast — never in
    /// <see cref="ErrorMessage"/>, which would blank the grid. Cleared by the
    /// host once shown via <see cref="ClearPtzError"/>.
    /// </summary>
    private string? _ptzErrorMessage;
    public string? PtzErrorMessage { get => _ptzErrorMessage; private set { _ptzErrorMessage = value; Raise(); } }
    public void ClearPtzError() => _ptzErrorMessage = null;

    private bool _isClassicLoggedIn;
    public bool IsClassicLoggedIn { get => _isClassicLoggedIn; private set { _isClassicLoggedIn = value; Raise(); } }

    public const string CertificateChangedMessage =
        "The controller's certificate changed. Open Settings to review and trust it.";

    /// <summary>
    /// Set by the TLS callback when it rejected the controller's certificate, so
    /// the failure that follows reports the real cause instead of the generic
    /// transport error. Read-and-cleared by <see cref="TakeCertificateRejected"/>.
    /// </summary>
    private int _certificateRejected;
    private bool TakeCertificateRejected() => Interlocked.Exchange(ref _certificateRejected, 0) == 1;

    /// <summary>
    /// Surfaces a certificate rejection that happened outside an API call (the
    /// RTSPS tunnel has no other route to the user). Streams are dead until the
    /// user re-pins, so the error card is the right surface.
    /// </summary>
    public void ShowCertificateRejected() => ErrorMessage = CertificateChangedMessage;

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

    public ProtectService(AppSettings settings, CertificateTrust trust)
    {
        _settings = settings;
        _trust = trust;

        _integration = new HttpClient(MakeHandler()) { Timeout = TimeSpan.FromSeconds(15) };
        _classic = new HttpClient(MakeHandler()) { Timeout = TimeSpan.FromSeconds(15) };
    }

    private HttpClientHandler MakeHandler()
    {
        // No automatic cookie handling: the classic API's TOKEN cookie is set
        // explicitly per request (like macOS). An auto-forwarded session cookie
        // on a login POST makes the controller reject it with 403 (CSRF guard),
        // which would break every re-login after the first.
        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AllowAutoRedirect = false
        };
        handler.SslProtocols = System.Security.Authentication.SslProtocols.Tls12
                               | System.Security.Authentication.SslProtocols.Tls13;
        // System trust first, then trust-on-first-use pinning of the controller's
        // key (see CertificateTrust). The pin is keyed by the configured
        // controller identity so the RTSPS tunnel consults the same one.
        handler.ServerCertificateCustomValidationCallback = (_, cert, _, errors) =>
        {
            if (cert == null) return false;
            var pinKey = ControllerAddress?.PinKey ?? _settings.IpAddress;
            var ok = _trust.Evaluate(pinKey, cert, errors);
            if (!ok) Interlocked.Exchange(ref _certificateRejected, 1);
            return ok;
        };
        return handler;
    }

    /// <summary>The configured controller, normalised (host, optional port, pin identity).</summary>
    public ControllerAddress? ControllerAddress => ControllerAddress.Parse(_settings.IpAddress);

    private Uri? MakeUrl(string path)
        => ControllerAddress is { } address ? new Uri($"{address.HttpsBase}/{path}") : null;

    /// <summary>Percent-encodes a controller-supplied identifier for use as one path segment.</summary>
    private static string PathSegment(string value) => Uri.EscapeDataString(value);

    // MARK: - Fetch camera list

    // Fetch-coalescing state, touched from arbitrary caller contexts (tray
    // toggle, refresh buttons, Settings). Guarded by _fetchLock.
    private readonly object _fetchLock = new();
    private Task? _fetchTask;
    private CancellationTokenSource? _fetchCts;
    private DateTime? _lastFetchSucceededAt;
    private ControllerRequestPolicy.PtzEnrichRecord? _lastPtzEnrich;

    /// <summary>
    /// Fetches the camera list, coalescing concurrent calls into one request
    /// chain (rapid panel toggles must not stack fetches against the
    /// controller's 10 req/s limit) and throttling automatic refreshes.
    /// <paramref name="forced"/> — a user-initiated refresh or Test Connection —
    /// bypasses the throttle but still joins an in-flight fetch.
    /// </summary>
    public Task FetchCamerasAsync(bool forced = false)
    {
        lock (_fetchLock)
        {
            if (_fetchTask is { } existing) return existing;
            if (!forced && ControllerRequestPolicy.ShouldSkipFetch(_lastFetchSucceededAt, DateTime.UtcNow))
                return Task.CompletedTask;
            _fetchCts?.Dispose();
            _fetchCts = new CancellationTokenSource();
            var ct = _fetchCts.Token;
            // Task.Run so no part of the fetch executes inside this lock: a
            // synchronously-failing fetch would otherwise clear _fetchTask
            // before it is even assigned (the runner's finally serializes on
            // the lock, which we still hold).
            var task = Task.Run(() => RunFetchAsync(forced, ct));
            _fetchTask = task;
            return task;
        }
    }

    /// <summary>
    /// Cancels an in-flight camera fetch. Called by the deferred stream
    /// teardown after the panel closes — a fetch that dies here must not
    /// surface an error card (see the cancellation check in PerformFetchAsync).
    /// </summary>
    public void CancelFetch()
    {
        lock (_fetchLock) _fetchCts?.Cancel();
    }

    private async Task RunFetchAsync(bool forced, CancellationToken ct)
    {
        try { await PerformFetchAsync(forced, ct).ConfigureAwait(false); }
        finally { lock (_fetchLock) _fetchTask = null; }
    }

    private async Task PerformFetchAsync(bool forced, CancellationToken ct)
    {
        Log.Line("[API] fetchCameras called");
        if (!Validate()) { Log.Line("[API] validate failed"); return; }
        IsLoading = true;

        try
        {
            var cameras = await RequestCameraListAsync(ct).ConfigureAwait(false);
            lock (_fetchLock) _lastFetchSucceededAt = DateTime.UtcNow;
            ApplySuccess(cameras);

            // If classic API credentials are configured, enrich PTZ flags —
            // throttled, since enrichment costs a login the controller audit-logs.
            // Only a SUCCESSFUL enrichment arms the throttle: recording a failed
            // attempt (e.g. a 429 in the panel-open request burst) would leave
            // the cameras flagged non-PTZ for the whole throttle window.
            if (!string.IsNullOrEmpty(_settings.Username) && !string.IsNullOrEmpty(_settings.Password)
                && (forced || !ShouldSkipPtzEnrich())
                && await EnrichPtzFlagsAsync(ct).ConfigureAwait(false))
            {
                lock (_fetchLock)
                    _lastPtzEnrich = new ControllerRequestPolicy.PtzEnrichRecord(
                        DateTime.UtcNow, _settings.Username, _settings.Password);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // A fetch cancelled by the deferred teardown isn't a failure the
            // user should see — leave the camera list and error state alone.
            IsLoading = false;
        }
        catch (Exception ex)
        {
            ApplyError(ex);
        }
    }

    private bool ShouldSkipPtzEnrich()
    {
        lock (_fetchLock)
            return ControllerRequestPolicy.ShouldSkipPtzEnrich(
                _lastPtzEnrich, _settings.Username, _settings.Password, DateTime.UtcNow);
    }

    /// <summary>
    /// One camera-list request, retried once after the limiter's 1-second
    /// window when the controller answers 429 — a rapid panel toggle should
    /// recover silently rather than surface a rate-limit error card.
    /// </summary>
    private async Task<IReadOnlyList<Camera>> RequestCameraListAsync(CancellationToken ct)
    {
        try
        {
            return await RequestCameraListOnceAsync(ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.StatusCode == 429)
        {
            Log.Line("[API] 429 — retrying after limiter window");
            await Task.Delay(TimeSpan.FromSeconds(1.1), ct).ConfigureAwait(false);
            return await RequestCameraListOnceAsync(ct).ConfigureAwait(false);
        }
    }

    private async Task<IReadOnlyList<Camera>> RequestCameraListOnceAsync(CancellationToken ct)
    {
        var url = MakeUrl("proxy/protect/integration/v1/cameras") ?? throw new InvalidOperationException("invalid URL");
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("X-API-Key", _settings.ApiKey);
        req.Headers.TryAddWithoutValidation("Accept", "application/json");

        using var resp = await _integration.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new ApiException((int)resp.StatusCode, body);

        return ParseCameraList(body);
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
            var (outcome, url) = await RequestRtspStreamUrlAsync(camera, tier, pinned).ConfigureAwait(false);
            switch (outcome)
            {
                case StreamRequestOutcome.Success:
                    if (tier != quality)
                        Log.Line($"[Stream] {quality} unavailable for {camera.Name}; using {tier}");
                    return (url!, tier);
                case StreamRequestOutcome.QualityUnavailable:
                    continue;
                case StreamRequestOutcome.Failed:
                    return null;
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

    /// <summary>
    /// Result of one stream-creation POST, so the quality-fallback ladder can
    /// tell "this camera doesn't offer that quality" (try the next tier) from
    /// rate-limiting or an unreachable controller (abort the ladder — see
    /// <see cref="ControllerRequestPolicy.AbortsQualityLadder"/>).
    /// </summary>
    private enum StreamRequestOutcome { Success, QualityUnavailable, Failed }

    private async Task<(StreamRequestOutcome outcome, string? url)> RequestRtspStreamUrlAsync(
        Camera camera, string quality, bool pinned)
    {
        Log.Line($"[Stream] requestRtspStreamURL({quality}) for {camera.Name}");
        var url = MakeUrl($"proxy/protect/integration/v1/cameras/{PathSegment(camera.Id)}/rtsps-stream");
        if (url == null) { Log.Line("[Stream] makeURL failed"); return (StreamRequestOutcome.Failed, null); }

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
                return (ControllerRequestPolicy.AbortsQualityLadder((int)resp.StatusCode)
                    ? StreamRequestOutcome.Failed : StreamRequestOutcome.QualityUnavailable, null);
            }

            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty(quality, out var v) || v.ValueKind != JsonValueKind.String)
                return (StreamRequestOutcome.QualityUnavailable, null);

            var key = StreamKey(camera.Id, quality);
            lock (_streamLock) { (pinned ? _pinnedStreams : _activeStreams).Add(key); }
            var playable = ToPlayableUrl(v.GetString()!);
            Log.Line($"[Stream] Created {quality} for {camera.Name}: {Log.RedactUrl(playable)}");
            return (StreamRequestOutcome.Success, playable);
        }
        catch (Exception ex)
        {
            Log.Line($"[Stream] request failed: {ex.Message}");
            return (StreamRequestOutcome.Failed, null);
        }
    }

    private static string StreamKey(string cameraId, string quality) => $"{cameraId}:{quality}";

    // MARK: - RTSP stream cleanup

    /// <summary>
    /// Releases every popover-owned allocation. The returned task completes when
    /// the DELETEs have been sent (or failed); callers other than quit ignore it.
    /// </summary>
    public Task CleanupStreams()
    {
        string[] keys;
        lock (_streamLock) { keys = _activeStreams.ToArray(); _activeStreams.Clear(); }
        return Task.WhenAll(keys.Select(DeleteByKey));
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

    public Task CleanupPinnedStreams()
    {
        string[] keys;
        lock (_streamLock) { keys = _pinnedStreams.ToArray(); _pinnedStreams.Clear(); }
        return Task.WhenAll(keys.Select(DeleteByKey));
    }

    private Task DeleteByKey(string key)
    {
        var parts = key.Split(':', 2);
        return parts.Length == 2 ? DeleteRtspStream(parts[0], parts[1]) : Task.CompletedTask;
    }

    /// <summary>
    /// Releases a server-side allocation. Fire-and-forget for callers during
    /// normal operation; quit awaits the returned task (bounded) so the
    /// controller isn't left holding sessions until its own timeout.
    /// </summary>
    private Task DeleteRtspStream(string cameraId, string quality)
    {
        var url = MakeUrl($"proxy/protect/integration/v1/cameras/{PathSegment(cameraId)}/rtsps-stream?qualities={quality}");
        if (url == null) return Task.CompletedTask;
        return Task.Run(async () =>
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Delete, url);
                req.Headers.TryAddWithoutValidation("X-API-Key", _settings.ApiKey);
                using var _ = await _integration.SendAsync(req).ConfigureAwait(false);
            }
            catch (Exception ex) { Log.Line($"[Stream] release failed: {ex.Message}"); }
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
                Log.Line($"[PTZ] classicLogin FAILED (HTTP {(int)resp.StatusCode})");
                IsClassicLoggedIn = false;
                SetCreds(null, null);
                return false;
            }

            var csrf = resp.Headers.TryGetValues("X-CSRF-Token", out var vals) ? vals.FirstOrDefault() : null;
            var token = resp.Headers.TryGetValues("Set-Cookie", out var cookies)
                ? ParseTokenCookie(cookies) : null;
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

    /// <summary>Extracts the classic-API session token from Set-Cookie headers.</summary>
    public static string? ParseTokenCookie(IEnumerable<string> setCookieHeaders)
    {
        foreach (var header in setCookieHeaders)
            if (header.StartsWith("TOKEN=", StringComparison.Ordinal))
            {
                var value = header["TOKEN=".Length..].Split(';', 2)[0].Trim();
                if (value.Length > 0) return value;
            }
        return null;
    }

    /// <summary>Attaches the captured session cookie + CSRF token to a classic-API request.</summary>
    private void AddClassicAuth(HttpRequestMessage req)
    {
        string? csrf, token;
        lock (_credLock) { csrf = _csrfToken; token = _tokenCookie; }
        if (!string.IsNullOrEmpty(csrf)) req.Headers.TryAddWithoutValidation("X-CSRF-Token", csrf);
        if (!string.IsNullOrEmpty(token)) req.Headers.TryAddWithoutValidation("Cookie", $"TOKEN={token}");
    }

    // MARK: - Package snapshot (classic API)

    /// <summary>
    /// Fetches a JPEG snapshot of a camera's package lens. The package stream
    /// runs at 2 fps, so a client joining it mid-GOP waits many seconds for the
    /// first keyframe — the UI bridges that gap with this snapshot. Classic API
    /// only: the Integration API has no package-snapshot endpoint.
    /// </summary>
    public async Task<byte[]?> FetchPackageSnapshotAsync(Camera camera)
    {
        if (camera.Secondary == null) return null;
        bool hasToken;
        lock (_credLock) hasToken = !string.IsNullOrEmpty(_tokenCookie);
        if (!hasToken && !await ClassicLoginAsync().ConfigureAwait(false)) return null;

        var (bytes, unauthorized) = await RequestPackageSnapshotAsync(camera).ConfigureAwait(false);
        if (bytes != null) return bytes;
        // Expired session (token timeout, controller restart): one fresh login,
        // one retry. Other failures just return null — a login wouldn't help,
        // and every login is audit-logged on the controller.
        if (!unauthorized || !await ClassicLoginAsync().ConfigureAwait(false)) return null;
        return (await RequestPackageSnapshotAsync(camera).ConfigureAwait(false)).bytes;
    }

    private async Task<(byte[]? bytes, bool unauthorized)> RequestPackageSnapshotAsync(Camera camera)
    {
        var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); // cache-buster: always a fresh capture
        var url = MakeUrl($"proxy/protect/api/cameras/{PathSegment(camera.Id)}/package-snapshot?ts={ts}");
        if (url == null) return (null, false);
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            AddClassicAuth(req);
            using var resp = await _classic.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Line($"[Snapshot] package-snapshot HTTP {(int)resp.StatusCode}");
                return (null, resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
            }
            var bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            return (bytes.Length > 0 ? bytes : null, false);
        }
        catch (Exception ex)
        {
            Log.Line($"[Snapshot] package-snapshot request failed: {ex.Message}");
            return (null, false);
        }
    }

    /// <summary>
    /// Applies classic-API PTZ/zoom capability flags to the current camera list.
    /// Best-effort (PTZ simply stays unavailable on failure), but returns whether
    /// flags were actually applied so the caller only throttles real successes.
    /// </summary>
    private async Task<bool> EnrichPtzFlagsAsync(CancellationToken ct = default)
    {
        if (!await ClassicLoginAsync().ConfigureAwait(false)) return false;
        var url = MakeUrl("proxy/protect/api/cameras");
        if (url == null) return false;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            AddClassicAuth(req);
            using var resp = await _classic.SendAsync(req, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Line($"[PTZ] enrichment fetch failed (HTTP {(int)resp.StatusCode})");
                return false;
            }
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            var classic = ParseCameraList(body);
            if (classic.Count == 0) return false; // don't wipe known flags on a transient empty response

            var ptz = classic.Where(c => c.IsPtz).Select(c => c.Id).ToHashSet();
            var zoom = classic.Where(c => c.CanZoom).Select(c => c.Id).ToHashSet();
            foreach (var cam in _cameras)
            {
                cam.IsPtz = ptz.Contains(cam.Id);
                cam.CanZoom = zoom.Contains(cam.Id);
            }
            Raise(nameof(Cameras));
            Log.Line($"[PTZ] enrichment applied: {ptz.Count} PTZ, {zoom.Count} zoom-capable");
            return true;
        }
        catch (Exception ex)
        {
            Log.Line($"[PTZ] enrichment failed: {ex.Message}");
            return false;
        }
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
                    Log.Line("[PTZ] login failed — PTZ unavailable");
                    PtzErrorMessage = TakeCertificateRejected()
                        ? CertificateChangedMessage
                        : "PTZ unavailable — check the username and password in Settings.";
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
        var url = MakeUrl($"proxy/protect/api/cameras/{PathSegment(cameraId)}/move");
        if (url == null) return;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            AddClassicAuth(req);
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
        Cameras = PreserveEnrichmentFlags(Cameras, cameras);
        IsLoading = false;
        ErrorMessage = null;
    }

    /// <summary>
    /// Carries classic-API enrichment (IsPtz/CanZoom) from the previous camera
    /// list onto a freshly fetched one. Integration API responses carry no
    /// featureFlags, so without this every fetch resets the flags to false —
    /// and the enrichment that restores them is throttled, so a panel reopen
    /// inside the throttle window would lose PTZ until the next enrichment.
    /// Flags are only ever carried forward (never cleared); the periodic
    /// enrichment remains the authority that can clear them.
    /// </summary>
    public static IReadOnlyList<Camera> PreserveEnrichmentFlags(
        IReadOnlyList<Camera> previous, IReadOnlyList<Camera> fresh)
    {
        if (previous.Count == 0) return fresh;
        var ptz = previous.Where(c => c.IsPtz).Select(c => c.Id).ToHashSet();
        var zoom = previous.Where(c => c.CanZoom).Select(c => c.Id).ToHashSet();
        if (ptz.Count == 0 && zoom.Count == 0) return fresh;
        foreach (var cam in fresh)
        {
            if (ptz.Contains(cam.Id)) cam.IsPtz = true;
            if (zoom.Contains(cam.Id)) cam.CanZoom = true;
        }
        return fresh;
    }

    private void ApplyError(Exception ex)
    {
        Log.Line($"[API] applyError: {ex.Message}");
        ErrorMessage = TakeCertificateRejected() ? CertificateChangedMessage : ex.Message;
        IsLoading = false;
    }

    private bool Validate()
    {
        if (ControllerAddress is null) { ErrorMessage = "No IP address configured. Open Settings."; return false; }
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
