using System.ComponentModel;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace QuickProtect.Core.Services;

/// <summary>
/// Checks GitHub for a newer release and surfaces it in Settings. Notify-only:
/// it never downloads or installs (the GitHub build is intentionally unsigned —
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
        _timer = new Timer(_ => _ = CheckForUpdateAsync(), null, TimeSpan.FromSeconds(3), Interval);
    }

    public async Task CheckForUpdateAsync()
    {
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
            UpdateAvailable = VersionCompare.IsNewer(remote, _currentVersion);
        }
        catch (Exception ex)
        {
            Log.Line($"[Update] check failed: {ex.Message}");
        }
        finally { IsChecking = false; }
    }

    public void Dispose()
    {
        _timer?.Dispose();
        _http.Dispose();
    }
}
