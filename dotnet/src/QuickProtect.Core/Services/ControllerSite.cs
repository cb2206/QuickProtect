using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace QuickProtect.Core.Services;

/// <summary>
/// One UniFi console (a "site") QuickProtect streams from: its address, the
/// Integration API key and the optional classic-API login used for PTZ. Port
/// of the macOS <c>ControllerSite</c>.
/// <para>
/// The site list (id, name, address) lives in preferences; the three secrets
/// live in the secret store under per-site accounts. The site migrated from
/// the single-controller configuration keeps the original account names
/// (<c>unifi.apiKey</c> …), so upgrading never moves a secret.
/// </para>
/// </summary>
public sealed class ControllerSite : INotifyPropertyChanged
{
    /// <summary>Id of the site migrated from the single-controller configuration.</summary>
    public const string LegacyId = "default";

    private readonly ISecretStore _secrets;

    /// <summary>Set by <see cref="AppSettings"/> to persist the list when the name or address changes.</summary>
    internal Action? OnListChange { get; set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// The address or API key actually changed (raised after the new value is
    /// stored; Settings re-applies unchanged text on focus loss, which doesn't count).
    /// </summary>
    public event EventHandler? ConnectionChanged;

    internal ControllerSite(string id, string name, string ipAddress, ISecretStore secrets,
                            string apiKey, string username, string password)
    {
        Id = id;
        _name = name;
        _ipAddress = ipAddress;
        _secrets = secrets;
        _apiKey = apiKey;
        _username = username;
        _password = password;
    }

    /// <summary>Stable id: <see cref="LegacyId"/> or a GUID string.</summary>
    public string Id { get; }

    private string _name;
    /// <summary>User-facing label shown on tiles, menus and Settings ("Inca", "BC285").</summary>
    public string Name
    {
        get => _name;
        set { if (_name == value) return; _name = value; OnListChange?.Invoke(); Raise(); Raise(nameof(DisplayName)); }
    }

    private string _ipAddress;
    public string IpAddress
    {
        get => _ipAddress;
        set
        {
            if (_ipAddress == value) return;
            _ipAddress = value;
            OnListChange?.Invoke();
            Raise();
            Raise(nameof(DisplayName));
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private string _apiKey;
    /// <summary>Integration API key. Sensitive — secret store only.</summary>
    public string ApiKey
    {
        get => _apiKey;
        set
        {
            if (_apiKey == value) return;
            _apiKey = value;
            _secrets.Set(Account(AppSettings.SecretKeys.ApiKey, Id), value);
            Raise();
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private string _username;
    /// <summary>Classic-API username (PTZ). Sensitive — secret store only.</summary>
    public string Username
    {
        get => _username;
        set { if (_username == value) return; _username = value; _secrets.Set(Account(AppSettings.SecretKeys.Username, Id), value); Raise(); }
    }

    private string _password;
    /// <summary>Classic-API password (PTZ). Sensitive — secret store only.</summary>
    public string Password
    {
        get => _password;
        set { if (_password == value) return; _password = value; _secrets.Set(Account(AppSettings.SecretKeys.Password, Id), value); Raise(); }
    }

    /// <summary>
    /// The user's label, else the address, else empty — the UI shows its
    /// localized "New Site" placeholder for an empty one (Core has no catalog).
    /// </summary>
    public string DisplayName
    {
        get
        {
            var trimmed = Name.Trim();
            if (trimmed.Length > 0) return trimmed;
            return IpAddress.Trim();
        }
    }

    /// <summary>Address and API key are both set, so the camera list can be fetched.</summary>
    public bool IsConfigured => !string.IsNullOrWhiteSpace(IpAddress) && !string.IsNullOrWhiteSpace(ApiKey);

    /// <summary>Secret-store account for one of a site's secrets. The legacy site keeps the old names.</summary>
    public static string Account(string baseKey, string siteId)
        => siteId == LegacyId ? baseKey : $"{baseKey}.{siteId}";

    /// <summary>Deletes this site's secrets (the site is being removed).</summary>
    internal void RemoveSecrets()
    {
        foreach (var key in new[] { AppSettings.SecretKeys.ApiKey, AppSettings.SecretKeys.Username, AppSettings.SecretKeys.Password })
            _secrets.Remove(Account(key, Id));
    }

    internal Dictionary<string, string> ListEntry()
        => new() { ["id"] = Id, ["name"] = Name, ["address"] = IpAddress };

    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
