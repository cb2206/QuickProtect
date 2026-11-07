using System.ComponentModel;
using System.Runtime.CompilerServices;
using QuickProtect.Core.Models;

namespace QuickProtect.Core.Services;

/// <summary>
/// Merges every configured site's <see cref="ProtectService"/> into the one
/// camera list the UI shows, and routes each per-camera call (streams, PTZ,
/// snapshots) to the console that camera belongs to. Port of the macOS
/// <c>ProtectHub</c>.
/// <para>
/// A site that fails (unreachable, rejected key, changed certificate) drops
/// out of the merged list and is reported in <see cref="SiteIssues"/>; the
/// panel only shows the full certificate card when no site is usable.
/// </para>
/// </summary>
public sealed class ProtectHub : INotifyPropertyChanged, IStreamAllocator, IDisposable
{
    /// <summary>A site that currently contributes no cameras, and why (a catalog key).</summary>
    public sealed record SiteIssue(string SiteId, string SiteName, string Message, bool IsCertificateChange);

    private readonly AppSettings _settings;
    private readonly Func<ControllerSite, ProtectService> _makeService;
    private readonly object _gate = new();
    private readonly Dictionary<string, ProtectService> _services = new();
    private readonly Dictionary<string, PropertyChangedEventHandler> _serviceHandlers = new();
    private readonly Dictionary<string, EventHandler> _connectionHandlers = new();
    private readonly Dictionary<string, PropertyChangedEventHandler> _siteHandlers = new();
    private IReadOnlyList<ControllerSite> _sites = Array.Empty<ControllerSite>();
    // Last known site of every camera any service listed — including a failing
    // site's, so its streams can still be released.
    private Dictionary<string, string> _siteForCamera = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>A site's address or API key changed (after the new value is stored).</summary>
    public event EventHandler<string>? ConnectionChanged;

    /// <summary>A site was removed; its pinned windows should close.</summary>
    public event EventHandler<string>? SiteRemoved;

    public ProtectHub(AppSettings settings, Func<ControllerSite, ProtectService> makeService)
    {
        _settings = settings;
        _makeService = makeService;
        Reconcile();
        _settings.SitesChanged += (_, _) => Reconcile();
    }

    // MARK: - Merged state

    private IReadOnlyList<Camera> _cameras = Array.Empty<Camera>();
    /// <summary>Cameras from every healthy site, in site order; a duplicate id is kept once.</summary>
    public IReadOnlyList<Camera> Cameras => _cameras;

    private bool _isLoading;
    /// <summary>Any site is fetching.</summary>
    public bool IsLoading => _isLoading;

    private IReadOnlyList<SiteIssue> _siteIssues = Array.Empty<SiteIssue>();
    public IReadOnlyList<SiteIssue> SiteIssues => _siteIssues;

    private CertificateChange? _blockingCertificateChange;
    /// <summary>
    /// A changed certificate while no site delivers cameras — the panel's
    /// full certificate card. With another site healthy the change is only an
    /// issue in <see cref="SiteIssues"/>.
    /// </summary>
    public CertificateChange? BlockingCertificateChange => _blockingCertificateChange;

    /// <summary>The first site's pending certificate change, for the review dialog.</summary>
    public CertificateChange? PendingCertificateChange
    {
        get { lock (_gate) return OrderedServices().Select(s => s.CertificateChange).FirstOrDefault(c => c != null); }
    }

    private string? _ptzErrorMessage;
    /// <summary>PTZ-only problems from any site (a catalog key), shown as a toast.</summary>
    public string? PtzErrorMessage => _ptzErrorMessage;

    public void ClearPtzError() => _ptzErrorMessage = null;

    public IReadOnlyList<ControllerSite> Sites => _sites;

    // MARK: - Services per site

    public ProtectService? ServiceForSite(string siteId)
    {
        lock (_gate) return _services.GetValueOrDefault(siteId);
    }

    public ProtectService? ServiceForCameraId(string cameraId)
    {
        lock (_gate)
            return _siteForCamera.TryGetValue(cameraId, out var site) ? _services.GetValueOrDefault(site) : null;
    }

    public ProtectService? ServiceFor(Camera camera)
        => (camera.SiteId.Length > 0 ? ServiceForSite(camera.SiteId) : null) ?? ServiceForCameraId(camera.Id);

    public ControllerSite? SiteFor(Camera camera)
    {
        string? id = camera.SiteId;
        if (string.IsNullOrEmpty(id)) lock (_gate) id = _siteForCamera.GetValueOrDefault(camera.Id);
        return _sites.FirstOrDefault(s => s.Id == id);
    }

    /// <summary>Site label for a camera's tile badge; null while only one site exists.</summary>
    public string? SiteBadge(Camera camera)
        => _sites.Count > 1 && SiteFor(camera) is { } site ? site.DisplayName : null;

    public CertificateChange? CertificateChangeFor(Camera camera) => ServiceFor(camera)?.CertificateChange;

    /// <summary>
    /// The pin identity for an RTSPS connection to <paramref name="connectHost"/>:
    /// the configured site whose host it is, so video and API share one pin.
    /// </summary>
    public string PinKeyFor(string connectHost)
    {
        foreach (var site in _sites)
            if (ControllerAddress.Parse(site.IpAddress) is { } address
                && string.Equals(address.Host, connectHost, StringComparison.OrdinalIgnoreCase))
                return address.PinKey;
        return connectHost;
    }

    private IEnumerable<ProtectService> OrderedServices()
        => _sites.Select(s => _services.GetValueOrDefault(s.Id)).OfType<ProtectService>();

    private void Reconcile()
    {
        var removed = new List<(string id, ProtectService service)>();
        lock (_gate)
        {
            var sites = _settings.Sites.ToList();
            var ids = sites.Select(s => s.Id).ToHashSet();
            foreach (var (id, service) in _services.Where(kv => !ids.Contains(kv.Key)).ToList())
            {
                service.PropertyChanged -= _serviceHandlers[id];
                _serviceHandlers.Remove(id);
                if (_sites.FirstOrDefault(s => s.Id == id) is { } oldSite)
                {
                    oldSite.ConnectionChanged -= _connectionHandlers[id];
                    oldSite.PropertyChanged -= _siteHandlers[id];
                }
                _connectionHandlers.Remove(id);
                _siteHandlers.Remove(id);
                _services.Remove(id);
                removed.Add((id, service));
            }
            foreach (var site in sites.Where(s => !_services.ContainsKey(s.Id)))
            {
                var service = _makeService(site);
                var siteId = site.Id;
                PropertyChangedEventHandler onService = (_, e) => OnServiceChanged(siteId, e);
                EventHandler onConnection = (_, _) => ConnectionChanged?.Invoke(this, siteId);
                PropertyChangedEventHandler onSite = (_, e) =>
                {
                    if (e.PropertyName == nameof(ControllerSite.DisplayName)) Recompute();
                };
                service.PropertyChanged += onService;
                site.ConnectionChanged += onConnection;
                site.PropertyChanged += onSite;
                _serviceHandlers[siteId] = onService;
                _connectionHandlers[siteId] = onConnection;
                _siteHandlers[siteId] = onSite;
                _services[siteId] = service;
            }
            _sites = sites;
        }
        foreach (var (id, service) in removed)
        {
            SiteRemoved?.Invoke(this, id);
            service.CancelFetch();
            // Releases go to the removed console with the credentials it still holds in memory.
            _ = service.CleanupStreams();
            _ = service.CleanupPinnedStreams();
        }
        Recompute();
    }

    private void OnServiceChanged(string siteId, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ProtectService.PtzErrorMessage))
        {
            if (ServiceForSite(siteId) is { PtzErrorMessage: { } message } service)
            {
                _ptzErrorMessage = message;
                service.ClearPtzError();
                Raise(nameof(PtzErrorMessage));
            }
            return;
        }
        if (e.PropertyName is nameof(ProtectService.Cameras) or nameof(ProtectService.IsLoading)
            or nameof(ProtectService.ErrorMessage) or nameof(ProtectService.CertificateChange))
            Recompute();
    }

    /// <summary>
    /// Rebuilds the merged camera list, loading flag and per-site issues, and
    /// distributes a newly added site's first cameras over the layout profiles
    /// (see <see cref="AppSettings.SeedSiteCamerasIfNeeded"/>). Raises only what changed.
    /// </summary>
    public void Recompute()
    {
        var changed = new List<string>();
        var toSeed = new List<(string site, List<string> ids)>();
        CertificateChange? pending = null;
        lock (_gate)
        {
            var merged = new List<Camera>();
            var seen = new HashSet<string>();
            var map = new Dictionary<string, string>();
            var issues = new List<SiteIssue>();
            var anyLoading = false;
            foreach (var site in _sites)
            {
                if (!_services.TryGetValue(site.Id, out var service)) continue;
                anyLoading |= service.IsLoading;
                var cameras = service.Cameras;
                foreach (var cam in cameras) map.TryAdd(cam.Id, site.Id);
                if (service.CertificateChange is { } change)
                {
                    pending ??= change;
                    issues.Add(new SiteIssue(site.Id, site.DisplayName, ProtectService.CertificateChangedMessage, true));
                    continue;
                }
                if (service.ErrorMessage is { } error)
                {
                    issues.Add(new SiteIssue(site.Id, site.DisplayName, error, false));
                    continue;
                }
                foreach (var cam in cameras)
                    if (seen.Add(cam.Id)) merged.Add(cam);
                if (cameras.Count > 0) toSeed.Add((site.Id, cameras.Select(c => c.Id).ToList()));
            }
            _siteForCamera = map;
            if (!SameCameras(merged, _cameras)) { _cameras = merged; changed.Add(nameof(Cameras)); }
            if (_isLoading != anyLoading) { _isLoading = anyLoading; changed.Add(nameof(IsLoading)); }
            if (!_siteIssues.SequenceEqual(issues)) { _siteIssues = issues; changed.Add(nameof(SiteIssues)); }
            var blocking = merged.Count == 0 ? pending : null;
            if (!Equals(blocking, _blockingCertificateChange))
            {
                _blockingCertificateChange = blocking;
                changed.Add(nameof(BlockingCertificateChange));
            }
        }
        // Outside the lock: seeding writes preferences and raises settings events.
        foreach (var (site, ids) in toSeed) _settings.SeedSiteCamerasIfNeeded(site, ids);
        foreach (var name in changed) Raise(name);
        // Pinned windows and Settings follow any site's certificate state.
        Raise(nameof(PendingCertificateChange));
    }

    private static bool SameCameras(IReadOnlyList<Camera> a, IReadOnlyList<Camera> b)
        => a.Count == b.Count && a.Zip(b).All(p => ReferenceEquals(p.First, p.Second)
            || (p.First.Id == p.Second.Id && p.First.Name == p.Second.Name && p.First.State == p.Second.State
                && p.First.SiteId == p.Second.SiteId && p.First.IsPtz == p.Second.IsPtz
                && p.First.CanZoom == p.Second.CanZoom));

    // MARK: - Fan-out

    /// <summary>Fetches every site's camera list concurrently (each service coalesces and throttles on its own).</summary>
    public async Task FetchCamerasAsync(bool forced = false)
    {
        List<ProtectService> all;
        lock (_gate) all = OrderedServices().ToList();
        await Task.WhenAll(all.Select(s => s.FetchCamerasAsync(forced)));
        Recompute();
    }

    public async Task RefetchForNewConnectionAsync(string siteId)
    {
        if (ServiceForSite(siteId) is { } service) await service.RefetchForNewConnectionAsync();
        Recompute();
    }

    private List<ProtectService> AllServices()
    {
        lock (_gate) return _services.Values.ToList();
    }

    public void CancelFetch() => AllServices().ForEach(s => s.CancelFetch());

    public Task CleanupStreams() => Task.WhenAll(AllServices().Select(s => s.CleanupStreams()));

    public Task CleanupPinnedStreams() => Task.WhenAll(AllServices().Select(s => s.CleanupPinnedStreams()));

    public Task ReleasesSettled() => Task.WhenAll(AllServices().Select(s => s.ReleasesSettled()));

    /// <summary>Trusts <paramref name="host"/>'s pending certificate through the service(s) using it.</summary>
    public void TrustPendingCertificate(string host)
    {
        var all = AllServices();
        var matching = all.Where(s => s.CertificateChange?.Host == host).ToList();
        if (matching.Count == 0)
            // A pin under another key format (listed in Settings): any service
            // can promote it in the shared store.
            all.FirstOrDefault()?.TrustPendingCertificate(host);
        else
            matching.ForEach(s => s.TrustPendingCertificate(host));
    }

    // MARK: - Per-camera routing

    public ControllerAddress? ControllerAddressFor(Camera camera) => ServiceFor(camera)?.ControllerAddress;

    public Task<(string url, string quality)?> CreateRtspStreamUrlAsync(Camera camera, string quality = "medium")
        => ServiceFor(camera)?.CreateRtspStreamUrlAsync(camera, quality)
           ?? Task.FromResult<(string url, string quality)?>(null);

    public Task<(string url, string quality)?> CreatePinnedStreamUrlAsync(Camera camera, string quality = "high")
        => ServiceFor(camera)?.CreatePinnedStreamUrlAsync(camera, quality)
           ?? Task.FromResult<(string url, string quality)?>(null);

    public void ReleaseStream(string cameraId, string quality)
        => ServiceForCameraId(cameraId)?.ReleaseStream(cameraId, quality);

    public void ReleasePinnedStream(string cameraId, string quality)
        => ServiceForCameraId(cameraId)?.ReleasePinnedStream(cameraId, quality);

    public Task<byte[]?> FetchPackageSnapshotAsync(Camera camera)
        => ServiceFor(camera)?.FetchPackageSnapshotAsync(camera) ?? Task.FromResult<byte[]?>(null);

    public void PtzSetAxes(string cameraId, double? pan = null, double? tilt = null, double? zoom = null)
        => ServiceForCameraId(cameraId)?.PtzSetAxes(cameraId, pan, tilt, zoom);

    public void PtzStopAll(string cameraId) => ServiceForCameraId(cameraId)?.PtzStopAll(cameraId);

    public void Dispose()
    {
        foreach (var service in AllServices()) service.Dispose();
    }

    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
