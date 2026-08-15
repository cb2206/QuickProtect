using System.ComponentModel;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace QuickProtect.Core.Services;

/// <summary>
/// Checks GitHub for a newer release and surfaces it in Settings. Notify-only:
/// it never downloads or installs (the GitHub build is unsigned —
/// see the macOS app's distribution notes). Port of the macOS <c>UpdateChecker</c>.
/// </summary>
public sealed class UpdateChecker : INotifyPropertyChanged, IDisposable
{
    private const string RepoOwner = "cb2206";
    private const string RepoName = "QuickProtect";
    private static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    private readonly string _currentVersion;
    private readonly HttpClient _http = new();
    private Timer? _timer;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private bool _updateAvailable;
    public bool UpdateAvailable { get => _updateAvailable; private set { _updateAvailable = value; Raise(); } }

    private string _latestVersion = "";
    public string LatestVersion { get => _latestVersion; private set { _latestVersion = value; Raise(); } }

    private string? _releaseUrl;
    public string? ReleaseUrl { get => _releaseUrl; private set { _releaseUrl = value; Raise(); } }

    private bool _isChecking;
    public bool IsChecking { get => _isChecking; private set { _isChecking = value; Raise(); } }

    public string ReleasesPageUrl => $"https://github.com/{RepoOwner}/{RepoName}/releases/latest";

    public UpdateChecker(string currentVersion)
    {
        _currentVersion = currentVersion;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("QuickProtect");
    }

    /// <summary>Initial check after a short delay, then daily.</summary>
    public void StartPeriodicChecks()
    {
        // Store/packaged builds are updated by their store or package
        // manager; never self-check (mirrors the macOS receipt guard).
        if (AppDistribution.IsExternallyManaged) return;
        _timer = new Timer(_ => _ = CheckForUpdateAsync(), null, TimeSpan.FromSeconds(3), Interval);
    }

    public async Task CheckForUpdateAsync()
    {
        if (AppDistribution.IsExternallyManaged) return;
        if (IsChecking) return;
        IsChecking = true;
        try
        {
            var url = $"https://api.github.com/repos/{RepoOwner}/{RepoName}/releases/latest";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");

            using var resp = await _http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return;
            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);

            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (!root.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String) return;

            var remote = tag.GetString()!.TrimStart('v', 'V');
            LatestVersion = remote;
            if (root.TryGetProperty("html_url", out var html) && html.ValueKind == JsonValueKind.String)
                ReleaseUrl = html.GetString();

            // Only announce when the release actually carries an asset for
            // this OS — releases ship all platforms under one tag, but a
            // platform's asset can lag (or a hotfix can be single-OS).
            var assetNames = new List<string>();
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
                foreach (var asset in assets.EnumerateArray())
                    if (asset.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String)
                        assetNames.Add(name.GetString()!);

            UpdateAvailable = VersionCompare.IsNewer(remote, _currentVersion)
                && HasCurrentPlatformAsset(assetNames);
        }
        catch (Exception ex)
        {
            Log.Line($"[Update] check failed: {ex.Message}");
        }
        finally { IsChecking = false; }
    }

    /// <summary>
    /// True when any asset name matches the running OS. The naming convention
    /// (<c>QuickProtect-&lt;ver&gt;-win-x64.exe</c>, <c>…-linux-x64.tar.gz</c>,
    /// <c>….dmg</c>) is a de facto API shared with the macOS app's
    /// <c>UpdateAssets</c> helper; keep the two in sync. Tokens include the
    /// leading hyphen so e.g. "darwin" never matches "win".
    /// </summary>
    public static bool HasCurrentPlatformAsset(IReadOnlyCollection<string> assetNames)
    {
        if (OperatingSystem.IsWindows()) return HasAsset(assetNames, "-win");
        if (OperatingSystem.IsLinux()) return HasAsset(assetNames, "-linux");
        // Development runs on macOS; match the mac artifact there.
        return HasAsset(assetNames, ".dmg") || HasAsset(assetNames, "-macos");
    }

    public static bool HasAsset(IReadOnlyCollection<string> assetNames, string token)
        => assetNames.Any(n => n.Contains(token, StringComparison.OrdinalIgnoreCase));

    public void Dispose()
    {
        _timer?.Dispose();
        _http.Dispose();
    }
}
