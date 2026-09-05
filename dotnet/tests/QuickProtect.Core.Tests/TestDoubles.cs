using System.Text.Json;
using QuickProtect.Core.Services;

namespace QuickProtect.Core.Tests;

/// <summary>In-memory <see cref="IPreferences"/> so settings logic is testable without disk.</summary>
public sealed class InMemoryPreferences : IPreferences
{
    private readonly Dictionary<string, JsonElement> _v = new();

    private JsonElement? Raw(string k) => _v.TryGetValue(k, out var e) ? e : null;

    public string? GetString(string k) => Raw(k) is { ValueKind: JsonValueKind.String } e ? e.GetString() : null;
    public bool? GetBool(string k) => Raw(k) is { } e && e.ValueKind is JsonValueKind.True or JsonValueKind.False ? e.GetBoolean() : null;
    public int? GetInt(string k) => Raw(k) is { ValueKind: JsonValueKind.Number } e && e.TryGetInt32(out var v) ? v : null;
    public double? GetDouble(string k) => Raw(k) is { ValueKind: JsonValueKind.Number } e && e.TryGetDouble(out var v) ? v : null;
    public T? GetJson<T>(string k) { if (Raw(k) is not { } e) return default; try { return e.Deserialize<T>(); } catch { return default; } }
    public bool Contains(string k) => _v.ContainsKey(k);
    public void Remove(string k) => _v.Remove(k);
    public IReadOnlyCollection<string> Keys => _v.Keys.ToArray();

    public void SetString(string k, string? val) => Store(k, val);
    public void SetBool(string k, bool val) => Store(k, val);
    public void SetInt(string k, int val) => Store(k, val);
    public void SetDouble(string k, double val) => Store(k, val);
    public void SetJson<T>(string k, T? val) => Store(k, val);

    private void Store<T>(string k, T val)
    {
        if (val is null) { _v.Remove(k); return; }
        _v[k] = JsonSerializer.SerializeToElement(val);
    }
}

/// <summary>In-memory <see cref="ISecretStore"/>.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _v = new();
    public string? Get(string a) => _v.TryGetValue(a, out var s) ? s : null;
    public void Set(string a, string? val) { if (string.IsNullOrEmpty(val)) _v.Remove(a); else _v[a] = val; }
    public void Remove(string a) => _v.Remove(a);
}
