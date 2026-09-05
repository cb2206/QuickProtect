using System.Collections.Concurrent;
using System.Text.Json;

namespace QuickProtect.Core.Services;

/// <summary>
/// Key/value preference store — the cross-platform stand-in for macOS
/// <c>UserDefaults</c>. Backed by a single JSON file in the user's config dir.
/// Values are stored as JSON elements so dictionaries/arrays round-trip the same
/// way the macOS app stored nested <c>[String: Any]</c> structures.
/// </summary>
public interface IPreferences
{
    string? GetString(string key);
    void SetString(string key, string? value);

    bool? GetBool(string key);
    void SetBool(string key, bool value);

    int? GetInt(string key);
    void SetInt(string key, int value);

    double? GetDouble(string key);
    void SetDouble(string key, double value);

    /// <summary>Reads an arbitrary JSON-shaped value (object/array) or null.</summary>
    T? GetJson<T>(string key);
    void SetJson<T>(string key, T? value);

    bool Contains(string key);
    void Remove(string key);

    /// <summary>Snapshot of every stored key (for prefix scans such as pending certificates).</summary>
    IReadOnlyCollection<string> Keys { get; }
}

/// <summary>JSON-file implementation of <see cref="IPreferences"/>. Thread-safe and atomic on write.</summary>
public sealed class JsonFilePreferences : IPreferences
{
    private readonly string _path;
    private readonly object _gate = new();
    private readonly ConcurrentDictionary<string, JsonElement> _values;

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public JsonFilePreferences(string? path = null)
    {
        _path = path ?? Path.Combine(AppPaths.ConfigDirectory, "preferences.json");
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        _values = Load(_path);
    }

    private static ConcurrentDictionary<string, JsonElement> Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                var dict = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
                if (dict != null) return new ConcurrentDictionary<string, JsonElement>(dict);
            }
        }
        catch (Exception ex)
        {
            // A corrupt prefs file should not crash the app; start fresh, keep a backup.
            try { File.Move(path, path + ".corrupt", overwrite: true); } catch { /* best effort */ }
            Console.Error.WriteLine($"[Preferences] load failed, starting fresh: {ex.Message}");
        }
        return new ConcurrentDictionary<string, JsonElement>();
    }

    private void Persist()
    {
        lock (_gate)
        {
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_values, Options));
            File.Move(tmp, _path, overwrite: true);
        }
    }

    private JsonElement? Raw(string key) => _values.TryGetValue(key, out var el) ? el : null;

    public string? GetString(string key) =>
        Raw(key) is { ValueKind: JsonValueKind.String } e ? e.GetString() : null;

    public bool? GetBool(string key) =>
        Raw(key) is { } e && e.ValueKind is JsonValueKind.True or JsonValueKind.False ? e.GetBoolean() : null;

    public int? GetInt(string key) =>
        Raw(key) is { ValueKind: JsonValueKind.Number } e && e.TryGetInt32(out var v) ? v : null;

    public double? GetDouble(string key) =>
        Raw(key) is { ValueKind: JsonValueKind.Number } e && e.TryGetDouble(out var v) ? v : null;

    public T? GetJson<T>(string key)
    {
        if (Raw(key) is not { } e) return default;
        try { return e.Deserialize<T>(); } catch { return default; }
    }

    public bool Contains(string key) => _values.ContainsKey(key);

    public IReadOnlyCollection<string> Keys => _values.Keys.ToArray();

    public void SetString(string key, string? value) { Store(key, value); }
    public void SetBool(string key, bool value) { Store(key, value); }
    public void SetInt(string key, int value) { Store(key, value); }
    public void SetDouble(string key, double value) { Store(key, value); }
    public void SetJson<T>(string key, T? value) { Store(key, value); }

    private void Store<T>(string key, T value)
    {
        if (value is null) { Remove(key); return; }
        var el = JsonSerializer.SerializeToElement(value);
        _values[key] = el;
        Persist();
    }

    public void Remove(string key)
    {
        if (_values.TryRemove(key, out _)) Persist();
    }
}
