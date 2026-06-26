using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QuickProtect.Core.Services;

/// <summary>
/// Stores sensitive strings (Integration API key, classic-API username/password).
/// Cross-platform stand-in for the macOS Keychain. An empty value removes the item.
/// </summary>
public interface ISecretStore
{
    string? Get(string account);
    void Set(string account, string? value);
    void Remove(string account);
}

public static class SecretStore
{
    /// <summary>Picks the best available backend for the current OS.</summary>
    public static ISecretStore Create()
    {
        if (OperatingSystem.IsWindows()) return new DpapiSecretStore();
        if (OperatingSystem.IsLinux() && LibSecretStore.IsAvailable()) return new LibSecretStore();
        return new FileSecretStore();
    }
}

/// <summary>
/// Windows secret store using DPAPI (CurrentUser scope). Secrets are encrypted
/// with the logged-in user's credentials and written to a JSON blob under
/// <c>%APPDATA%\QuickProtect</c>. Comparable security to the macOS Keychain's
/// AfterFirstUnlock / ThisDeviceOnly: tied to the user, never roams.
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private readonly string _path;
    private readonly object _gate = new();

    public DpapiSecretStore(string? path = null)
        => _path = path ?? Path.Combine(AppPaths.ConfigDirectory, "secrets.dat");

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_path)) return new();
        try
        {
            var protectedBytes = File.ReadAllBytes(_path);
            if (protectedBytes.Length == 0) return new();
#pragma warning disable CA1416 // guarded by SecretStore.Create() / IsWindows
            var plain = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
#pragma warning restore CA1416
            return JsonSerializer.Deserialize<Dictionary<string, string>>(Encoding.UTF8.GetString(plain)) ?? new();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Secrets] load failed: {ex.Message}");
            return new();
        }
    }

    private void Save(Dictionary<string, string> map)
    {
        var json = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(map));
#pragma warning disable CA1416
        var protectedBytes = ProtectedData.Protect(json, null, DataProtectionScope.CurrentUser);
#pragma warning restore CA1416
        var tmp = _path + ".tmp";
        File.WriteAllBytes(tmp, protectedBytes);
        File.Move(tmp, _path, overwrite: true);
    }

    public string? Get(string account)
    {
        lock (_gate) return Load().TryGetValue(account, out var v) ? v : null;
    }

    public void Set(string account, string? value)
    {
        lock (_gate)
        {
            var map = Load();
            if (string.IsNullOrEmpty(value)) map.Remove(account);
            else map[account] = value;
            Save(map);
        }
    }

    public void Remove(string account) => Set(account, null);
}

/// <summary>
/// Linux secret store backed by the Secret Service (GNOME Keyring / KWallet) via
/// the <c>secret-tool</c> CLI from libsecret-tools — encrypted at rest like the
/// macOS Keychain. Used when <c>secret-tool</c> is on PATH; otherwise the app
/// falls back to <see cref="FileSecretStore"/>.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class LibSecretStore : ISecretStore
{
    private const string Service = "com.cb.quickprotect";

    public static bool IsAvailable()
    {
        try { return RunSecretTool("--version", null, out _) >= 0; }
        catch { return false; }
    }

    public string? Get(string account)
    {
        var code = RunSecretTool($"lookup service {Service} account {Quote(account)}", null, out var stdout);
        return code == 0 && stdout.Length > 0 ? stdout.TrimEnd('\n') : null;
    }

    public void Set(string account, string? value)
    {
        if (string.IsNullOrEmpty(value)) { Remove(account); return; }
        RunSecretTool($"store --label={Quote("QuickProtect")} service {Service} account {Quote(account)}",
            stdin: value, out _);
    }

    public void Remove(string account)
        => RunSecretTool($"clear service {Service} account {Quote(account)}", null, out _);

    private static string Quote(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";

    /// <summary>Runs secret-tool, returning its exit code (or −1 if it couldn't start).</summary>
    private static int RunSecretTool(string args, string? stdin, out string stdout)
    {
        stdout = "";
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("secret-tool", args)
            {
                RedirectStandardInput = stdin != null,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            using var p = System.Diagnostics.Process.Start(psi);
            if (p == null) return -1;
            if (stdin != null) { p.StandardInput.Write(stdin); p.StandardInput.Close(); }
            stdout = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return p.HasExited ? p.ExitCode : -1;
        }
        catch { return -1; }
    }
}

/// <summary>
/// Linux/fallback secret store: a JSON file with owner-only permissions (0600)
/// under the user config dir. Not encrypted at rest — a follow-up can swap in
/// libsecret (GNOME Keyring) via a P/Invoke or the <c>SecretService</c> D-Bus
/// API for parity with the Keychain. Documented as a known gap.
/// </summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _path;
    private readonly object _gate = new();

    public FileSecretStore(string? path = null)
        => _path = path ?? Path.Combine(AppPaths.ConfigDirectory, "secrets.json");

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_path)) return new();
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path)) ?? new();
        }
        catch { return new(); }
    }

    private void Save(Dictionary<string, string> map)
    {
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(map));
        File.Move(tmp, _path, overwrite: true);
        if (!OperatingSystem.IsWindows())
        {
            try { File.SetUnixFileMode(_path, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
            catch { /* best effort */ }
        }
    }

    public string? Get(string account)
    {
        lock (_gate) return Load().TryGetValue(account, out var v) ? v : null;
    }

    public void Set(string account, string? value)
    {
        lock (_gate)
        {
            var map = Load();
            if (string.IsNullOrEmpty(value)) map.Remove(account);
            else map[account] = value;
            Save(map);
        }
    }

    public void Remove(string account) => Set(account, null);
}
