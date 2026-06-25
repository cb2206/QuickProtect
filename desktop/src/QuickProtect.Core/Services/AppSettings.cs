using System.ComponentModel;
using System.Runtime.CompilerServices;
using QuickProtect.Core.Models;

namespace QuickProtect.Core.Services;

/// <summary>
/// Application settings and per-camera/per-profile layout state. Cross-platform
/// port of the macOS <c>AppSettings</c>: connection details, stream-quality
/// preferences, layout profiles (camera order/size/visibility), pinned floating
/// windows, appearance, and the global hotkey. Sensitive values go through
/// <see cref="ISecretStore"/>; everything else through <see cref="IPreferences"/>.
/// </summary>
public sealed class AppSettings : INotifyPropertyChanged
{
    private readonly IPreferences _prefs;
    private readonly ISecretStore _secrets;
    public ILaunchAtLogin LaunchManager { get; set; } = new NoopLaunchAtLogin();

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public static AppSettings Shared { get; private set; } = null!;
    public static AppSettings Configure(IPreferences prefs, ISecretStore secrets)
        => Shared = new AppSettings(prefs, secrets);

    public AppSettings(IPreferences prefs, ISecretStore secrets)
    {
        _prefs = prefs;
        _secrets = secrets;
        _ipAddress = _prefs.GetString(Keys.IpAddress) ?? "";
        _apiKey = LoadSecret(Keys.ApiKey);
        _usePlainRtsp = _prefs.GetBool(Keys.UsePlainRtsp) ?? true;
        _username = LoadSecret(Keys.Username);
        _password = LoadSecret(Keys.Password);
        _defaultStreamQuality = StreamQualityExtensions.FromRawValue(_prefs.GetString(Keys.DefaultStreamQuality)) ?? StreamQuality.Auto;
        _appearance = (AppearanceMode)(_prefs.GetInt(Keys.Appearance) ?? 0);
        _accentColorHex = _prefs.GetString(Keys.AccentColorHex) ?? "0a84ff";
        _hasCompletedOnboarding = _prefs.GetBool(Keys.HasCompletedOnboarding) ?? false;
        _showFocusOverlayControls = _prefs.GetBool(Keys.ShowFocusOverlayControls) ?? true;
        _speakerEnabled = _prefs.GetBool(Keys.SpeakerEnabled) ?? false;
        _snapshotDestination = (SnapshotDestination)(_prefs.GetInt(Keys.SnapshotDestination) ?? 0);
        _snapshotFolder = _prefs.GetString(Keys.SnapshotFolder);
        _activeProfileId = _prefs.GetString(Keys.ActiveProfileId) ?? DefaultProfileId;
        MigrateLayoutProfilesIfNeeded();
    }

    // MARK: - Connection

    private string _ipAddress;
    public string IpAddress
    {
        get => _ipAddress;
        set { _ipAddress = value; _prefs.SetString(Keys.IpAddress, value); Raise(); }
    }

    private string _apiKey;
    public string ApiKey
    {
        get => _apiKey;
        set { _apiKey = value; _secrets.Set(Keys.ApiKey, value); Raise(); }
    }

    private string _username;
    public string Username
    {
        get => _username;
        set { _username = value; _secrets.Set(Keys.Username, value); Raise(); }
    }

    private string _password;
    public string Password
    {
        get => _password;
        set { _password = value; _secrets.Set(Keys.Password, value); Raise(); }
    }

    private bool _usePlainRtsp;
    public bool UsePlainRtsp
    {
        get => _usePlainRtsp;
        set { _usePlainRtsp = value; _prefs.SetBool(Keys.UsePlainRtsp, value); Raise(); }
    }

    // MARK: - Appearance / behavior

    public enum AppearanceMode { Auto = 0, Light = 1, Dark = 2 }
    public enum SnapshotDestination { Clipboard = 0, Folder = 1 }

    private AppearanceMode _appearance;
    public AppearanceMode Appearance
    {
        get => _appearance;
        set { _appearance = value; _prefs.SetInt(Keys.Appearance, (int)value); Raise(); }
    }

    private string _accentColorHex;
    public string AccentColorHex
    {
        get => _accentColorHex;
        set { _accentColorHex = value; _prefs.SetString(Keys.AccentColorHex, value); Raise(); }
    }

    private bool _hasCompletedOnboarding;
    public bool HasCompletedOnboarding
    {
        get => _hasCompletedOnboarding;
        set { _hasCompletedOnboarding = value; _prefs.SetBool(Keys.HasCompletedOnboarding, value); Raise(); }
    }

    private bool _showFocusOverlayControls;
    public bool ShowFocusOverlayControls
    {
        get => _showFocusOverlayControls;
        set { _showFocusOverlayControls = value; _prefs.SetBool(Keys.ShowFocusOverlayControls, value); Raise(); }
    }

    private bool _speakerEnabled;
    public bool SpeakerEnabled
    {
        get => _speakerEnabled;
        set { _speakerEnabled = value; _prefs.SetBool(Keys.SpeakerEnabled, value); Raise(); }
    }

    private SnapshotDestination _snapshotDestination;
    public SnapshotDestination SnapshotDest
    {
        get => _snapshotDestination;
        set { _snapshotDestination = value; _prefs.SetInt(Keys.SnapshotDestination, (int)value); Raise(); }
    }

    private string? _snapshotFolder;
    /// <summary>Plain folder path (Windows/Linux have no security-scoped bookmarks).</summary>
    public string? SnapshotFolder
    {
        get => _snapshotFolder;
        set { _snapshotFolder = value; if (value == null) _prefs.Remove(Keys.SnapshotFolder); else _prefs.SetString(Keys.SnapshotFolder, value); Raise(); }
    }

    public bool LaunchAtLogin
    {
        get => LaunchManager.IsEnabled;
        set { LaunchManager.SetEnabled(value); Raise(); }
    }

    public bool HasShownAutoStartPrompt
    {
        get => _prefs.GetBool(Keys.AutoStartPromptShown) ?? false;
        set => _prefs.SetBool(Keys.AutoStartPromptShown, value);
    }

    // MARK: - Stream quality (global + per-camera)

    private StreamQuality _defaultStreamQuality;
    public StreamQuality DefaultStreamQuality
    {
        get => _defaultStreamQuality;
        set { _defaultStreamQuality = value; _prefs.SetString(Keys.DefaultStreamQuality, value.RawValue()); Raise(); }
    }

    public StreamQuality? StreamQualityFor(string id)
        => StreamQualityExtensions.FromRawValue(GetStringMap(Keys.CameraStreamQualities).GetValueOrDefault(id));

    public void SetStreamQuality(StreamQuality? quality, string id)
    {
        var map = GetStringMap(Keys.CameraStreamQualities);
        if (quality is { } q) map[id] = q.RawValue(); else map.Remove(id);
        _prefs.SetJson(Keys.CameraStreamQualities, map);
    }

    public StreamQuality EffectiveStreamQuality(string id) => StreamQualityFor(id) ?? DefaultStreamQuality;

    // MARK: - Layout profiles

    public const string DefaultProfileId = "default";
    public string DefaultProfileName => "Default";

    public sealed record LayoutProfile(string Id, string Name);

    private string _activeProfileId;
    public string ActiveProfileId
    {
        get => _activeProfileId;
        set
        {
            if (_activeProfileId == value) return;
            _activeProfileId = value;
            _prefs.SetString(Keys.ActiveProfileId, value);
            Raise();
        }
    }

    public IReadOnlyList<LayoutProfile> Profiles()
    {
        var raw = _prefs.GetJson<List<Dictionary<string, string>>>(Keys.Profiles) ?? new();
        var list = raw.Where(d => d.ContainsKey("id") && d.ContainsKey("name"))
                      .Select(d => new LayoutProfile(d["id"], d["name"])).ToList();
        return list.Count == 0 ? new List<LayoutProfile> { new(DefaultProfileId, DefaultProfileName) } : list;
    }

    public LayoutProfile ActiveProfile
    {
        get { var all = Profiles(); return all.FirstOrDefault(p => p.Id == ActiveProfileId) ?? all[0]; }
    }

    private void SaveProfiles(IEnumerable<LayoutProfile> list)
    {
        _prefs.SetJson(Keys.Profiles, list.Select(p => new Dictionary<string, string> { ["id"] = p.Id, ["name"] = p.Name }).ToList());
        Raise(nameof(Profiles));
    }

    /// <summary>Stored content for a profile: order / sizes / hidden.</summary>
    private sealed class ProfileContent
    {
        public List<string> order { get; set; } = new();
        public Dictionary<string, int> sizes { get; set; } = new();
        public List<string> hidden { get; set; } = new();
    }

    private Dictionary<string, ProfileContent> AllLayouts()
        => _prefs.GetJson<Dictionary<string, ProfileContent>>(Keys.ProfileLayout) ?? new();

    private ProfileContent Layout(string id)
        => AllLayouts().TryGetValue(id, out var c) ? c : new ProfileContent();

    private void SaveLayout(string id, ProfileContent content)
    {
        var all = AllLayouts();
        all[id] = content;
        _prefs.SetJson(Keys.ProfileLayout, all);
    }

    public void SwitchProfile(string id)
    {
        if (!Profiles().Any(p => p.Id == id)) return;
        ActiveProfileId = id;
        LayoutProfileChanged?.Invoke(this, EventArgs.Empty);
    }

    public event EventHandler? LayoutProfileChanged;

    public string CreateProfile(string name)
    {
        var newId = Guid.NewGuid().ToString();
        SaveLayout(newId, Layout(ActiveProfileId));
        SaveProfiles(Profiles().Append(new LayoutProfile(newId, name)));
        SwitchProfile(newId);
        return newId;
    }

    public void RenameProfile(string id, string name)
    {
        var list = Profiles().ToList();
        var idx = list.FindIndex(p => p.Id == id);
        if (idx < 0) return;
        list[idx] = list[idx] with { Name = name };
        SaveProfiles(list);
    }

    public void DeleteProfile(string id)
    {
        var list = Profiles().ToList();
        if (list.Count <= 1) return;
        var idx = list.FindIndex(p => p.Id == id);
        if (idx < 0) return;
        list.RemoveAt(idx);
        var all = AllLayouts();
        all.Remove(id);
        _prefs.SetJson(Keys.ProfileLayout, all);
        SaveProfiles(list);
        if (ActiveProfileId == id) SwitchProfile(list[0].Id);
    }

    // MARK: - Camera order / size / visibility (per active profile)

    public IReadOnlyList<string> CameraOrder() => Layout(ActiveProfileId).order;

    public void SetCameraOrder(IEnumerable<string> ids)
    {
        var c = Layout(ActiveProfileId); c.order = ids.ToList(); SaveLayout(ActiveProfileId, c);
    }

    public IReadOnlyList<Camera> OrderedCameras(IReadOnlyList<Camera> cameras)
    {
        var order = CameraOrder();
        if (order.Count == 0) return cameras;
        var index = order.Select((id, i) => (id, i)).ToDictionary(t => t.id, t => t.i);
        return cameras.OrderBy(c => index.TryGetValue(c.Id, out var i) ? i : int.MaxValue).ToList();
    }

    public enum CameraSize { Small = 1, Medium = 2, Large = 4 }

    public CameraSize? SizeFor(string id)
        => Layout(ActiveProfileId).sizes.TryGetValue(id, out var v) ? (CameraSize)v : null;

    public void SetSize(CameraSize? size, string id)
    {
        var c = Layout(ActiveProfileId);
        if (size is { } s) c.sizes[id] = (int)s; else c.sizes.Remove(id);
        SaveLayout(ActiveProfileId, c);
    }

    public bool IsHidden(string id) => Layout(ActiveProfileId).hidden.Contains(id);

    public void SetHidden(bool hidden, string id)
    {
        var c = Layout(ActiveProfileId);
        if (hidden) { if (!c.hidden.Contains(id)) c.hidden.Add(id); }
        else c.hidden.RemoveAll(x => x == id);
        SaveLayout(ActiveProfileId, c);
        Raise(nameof(IsHidden));
    }

    public IReadOnlyList<Camera> VisibleCameras(IReadOnlyList<Camera> cameras)
        => cameras.Where(c => !IsHidden(c.Id)).ToList();

    public void AddHiddenCamera(string id, IReadOnlyList<string> visibleOrder)
    {
        SetHidden(false, id);
        var order = visibleOrder.Where(x => x != id).ToList();
        order.Add(id);
        SetCameraOrder(order);
    }

    // MARK: - Pinned floating windows (global)

    public sealed record PinnedCameraState(string CameraId, double? X, double? Y, double? W, double? H);

    private Dictionary<string, Dictionary<string, double>> PinnedRaw()
        => _prefs.GetJson<Dictionary<string, Dictionary<string, double>>>(Keys.PinnedCameras) ?? new();

    public IReadOnlyList<PinnedCameraState> PinnedCameras()
        => PinnedRaw().Select(kv =>
        {
            var d = kv.Value;
            var w = d.GetValueOrDefault("w");
            var h = d.GetValueOrDefault("h");
            return w > 0 && h > 0
                ? new PinnedCameraState(kv.Key, d.GetValueOrDefault("x"), d.GetValueOrDefault("y"), w, h)
                : new PinnedCameraState(kv.Key, null, null, null, null);
        }).ToList();

    public bool IsPinned(string id) => PinnedRaw().ContainsKey(id);

    public void SetPinned(string id, (double x, double y, double w, double h)? frame = null)
    {
        var all = PinnedRaw();
        all[id] = frame is { } f
            ? new() { ["x"] = f.x, ["y"] = f.y, ["w"] = f.w, ["h"] = f.h }
            : new();
        _prefs.SetJson(Keys.PinnedCameras, all);
        Raise(nameof(PinnedCameras));
    }

    public void RemovePinned(string id)
    {
        var all = PinnedRaw();
        if (!all.Remove(id)) return;
        _prefs.SetJson(Keys.PinnedCameras, all);
        Raise(nameof(PinnedCameras));
    }

    // MARK: - Cached aspect ratios

    public double? CachedAspectRatio(string id)
    {
        var dict = _prefs.GetJson<Dictionary<string, Dictionary<string, double>>>(Keys.VideoDimensions);
        if (dict != null && dict.TryGetValue(id, out var dims)
            && dims.TryGetValue("w", out var w) && dims.TryGetValue("h", out var h) && w > 0 && h > 0)
            return w / h;
        return null;
    }

    public void CacheVideoDimensions(double width, double height, string id)
    {
        if (width <= 0 || height <= 0) return;
        var dict = _prefs.GetJson<Dictionary<string, Dictionary<string, double>>>(Keys.VideoDimensions) ?? new();
        dict[id] = new() { ["w"] = width, ["h"] = height };
        _prefs.SetJson(Keys.VideoDimensions, dict);
    }

    // MARK: - Global hotkey (stored generically; the platform layer maps to native codes)

    public (int keyCode, int modifiers)? GlobalHotkey()
        => _prefs.Contains(Keys.HotkeyCode)
            ? (_prefs.GetInt(Keys.HotkeyCode) ?? 0, _prefs.GetInt(Keys.HotkeyMods) ?? 0)
            : null;

    public void SetGlobalHotkey(int keyCode, int modifiers)
    {
        _prefs.SetInt(Keys.HotkeyCode, keyCode);
        _prefs.SetInt(Keys.HotkeyMods, modifiers);
        Raise(nameof(GlobalHotkey));
    }

    public void ClearGlobalHotkey()
    {
        _prefs.Remove(Keys.HotkeyCode);
        _prefs.Remove(Keys.HotkeyMods);
        Raise(nameof(GlobalHotkey));
    }

    // MARK: - Helpers

    private Dictionary<string, string> GetStringMap(string key)
        => _prefs.GetJson<Dictionary<string, string>>(key) ?? new();

    private string LoadSecret(string account)
    {
        var value = _secrets.Get(account);
        if (!string.IsNullOrEmpty(value)) return value;
        // Migrate any legacy plaintext value left in prefs into the secret store.
        var legacy = _prefs.GetString(account);
        if (!string.IsNullOrEmpty(legacy))
        {
            _secrets.Set(account, legacy);
            _prefs.Remove(account);
            return legacy;
        }
        return "";
    }

    /// <summary>One-time migration of pre-profiles layout into a built-in "Default" profile.</summary>
    private void MigrateLayoutProfilesIfNeeded()
    {
        if (_prefs.Contains(Keys.Profiles)) return;
        var content = new ProfileContent();
        var legacyHidden = _prefs.GetJson<List<string>>(Keys.HiddenCameras);
        if (legacyHidden is { Count: > 0 }) content.hidden = legacyHidden;

        var all = AllLayouts();
        all[DefaultProfileId] = content;
        _prefs.SetJson(Keys.ProfileLayout, all);
        _prefs.SetJson(Keys.Profiles, new List<Dictionary<string, string>>
        {
            new() { ["id"] = DefaultProfileId, ["name"] = DefaultProfileName }
        });
        _prefs.SetString(Keys.ActiveProfileId, DefaultProfileId);
        _prefs.Remove(Keys.HiddenCameras);
    }

    // MARK: - Keys (kept identical to the macOS app's UserDefaults keys)

    private static class Keys
    {
        public const string IpAddress = "unifi.ipAddress";
        public const string ApiKey = "unifi.apiKey";
        public const string UsePlainRtsp = "unifi.usePlainRtsp";
        public const string HiddenCameras = "unifi.hiddenCameras";
        public const string Profiles = "unifi.profiles";
        public const string ProfileLayout = "unifi.profileLayout";
        public const string ActiveProfileId = "unifi.activeProfileID";
        public const string VideoDimensions = "unifi.videoDimensions";
        public const string HotkeyCode = "unifi.hotkeyCode";
        public const string HotkeyMods = "unifi.hotkeyMods";
        public const string Username = "unifi.username";
        public const string Password = "unifi.password";
        public const string AutoStartPromptShown = "unifi.autoStartPromptShown";
        public const string Appearance = "unifi.appearance";
        public const string AccentColorHex = "unifi.accentColorHex";
        public const string HasCompletedOnboarding = "unifi.hasCompletedOnboarding";
        public const string ShowFocusOverlayControls = "unifi.showFocusOverlayControls";
        public const string SpeakerEnabled = "unifi.speakerEnabled";
        public const string SnapshotDestination = "unifi.snapshotDestination";
        public const string SnapshotFolder = "unifi.snapshotFolder";
        public const string DefaultStreamQuality = "unifi.defaultStreamQuality";
        public const string CameraStreamQualities = "unifi.cameraStreamQualities";
        public const string PinnedCameras = "unifi.pinnedCameras";
    }
}
