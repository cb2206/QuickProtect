using System.Diagnostics;
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

    /// <summary>
    /// Loads the map. <paramref name="unreadable"/> is true when a file exists
    /// but could not be decrypted or parsed — the caller must not overwrite it
    /// blindly, since a transient DPAPI failure would otherwise wipe every
    /// credential on the next write.
    /// </summary>
    private Dictionary<string, string> Load(out bool unreadable)
    {
        unreadable = false;
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
            Log.Line($"[Secrets] load failed: {ex.Message}");
            unreadable = true;
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
        lock (_gate) return Load(out _).TryGetValue(account, out var v) ? v : null;
    }

    public void Set(string account, string? value)
    {
        lock (_gate)
        {
            var map = Load(out var unreadable);
            if (unreadable)
            {
                // Keep the undecryptable blob around rather than silently
                // replacing it with a one-entry file.
                var backup = _path + ".unreadable";
                try { File.Copy(_path, backup, overwrite: true); } catch { /* best effort */ }
                Log.Line($"[Secrets] previous store was unreadable; kept a copy at {backup}");
            }
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
/// macOS Keychain. Used when <c>secret-tool</c> is on PATH.
///
/// The daemon can be absent, locked, or unreachable (no session bus, a
/// headless login), in which case <c>secret-tool</c> fails or blocks on an
/// unlock prompt. Every call is therefore bounded by a timeout (the child is
/// killed on expiry) and a failed <c>store</c> falls back to the owner-only
/// <see cref="FileSecretStore"/> — with a log line — so the API key the user
/// just typed is never silently dropped.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class LibSecretStore : ISecretStore
{
    private const string Service = "com.cb.quickprotect";
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    private readonly FileSecretStore _fallback = new();

    public static bool IsAvailable()
    {
        try { return RunSecretTool("--version", null, TimeSpan.FromSeconds(2), out _) >= 0; }
        catch { return false; }
    }

    public string? Get(string account)
    {
        var code = RunSecretTool($"lookup service {Service} account {Quote(account)}", null, Timeout, out var stdout);
        if (code == 0 && stdout.Length > 0) return stdout.TrimEnd('\n');
        // Not in the keyring (or the keyring is unavailable): honour a value the
        // fallback captured while the keyring was unreachable.
        return _fallback.Get(account);
    }

    public void Set(string account, string? value)
    {
        if (string.IsNullOrEmpty(value)) { Remove(account); return; }
        var code = RunSecretTool($"store --label={Quote("QuickProtect")} service {Service} account {Quote(account)}",
            stdin: value, Timeout, out _);
        if (code == 0)
        {
            _fallback.Remove(account);
            return;
        }
        Log.Line($"[Secrets] secret-tool store failed (exit {code}); keeping '{account}' in the owner-only file store instead");
        _fallback.Set(account, value);
    }

    public void Remove(string account)
    {
        RunSecretTool($"clear service {Service} account {Quote(account)}", null, Timeout, out _);
        _fallback.Remove(account);
    }

    private static string Quote(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";

    /// <summary>
    /// Runs secret-tool, returning its exit code (−1 if it couldn't start or
    /// didn't finish within <paramref name="timeout"/>, in which case it is
    /// killed). The secret travels over stdin, never the command line.
    /// </summary>
    private static int RunSecretTool(string args, string? stdin, TimeSpan timeout, out string stdout)
    {
        stdout = "";
        try
        {
            var psi = new ProcessStartInfo("secret-tool", args)
            {
                RedirectStandardInput = stdin != null,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            using var p = Process.Start(psi);
            if (p == null) return -1;
            if (stdin != null) { p.StandardInput.Write(stdin); p.StandardInput.Close(); }
            // Drain both pipes concurrently so a chatty child can't block on a
            // full stderr buffer, and bound the whole thing by the timeout.
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit((int)timeout.TotalMilliseconds))
            {
                try { p.Kill(entireProcessTree: true); } catch { /* already gone */ }
                Log.Line("[Secrets] secret-tool timed out (keyring locked or unavailable?)");
                return -1;
            }
            p.WaitForExit(); // flush async output handlers
            stdout = outTask.GetAwaiter().GetResult();
            _ = errTask.GetAwaiter().GetResult();
            return p.ExitCode;
        }
        catch { return -1; }
    }
}

/// <summary>
/// Linux/fallback secret store: a JSON file with owner-only permissions (0600)
/// under the user config dir. Not encrypted at rest — used when no Secret
/// Service is available (documented in the privacy policy). The file is created
/// with its final mode so plaintext is never, even briefly, readable by other
/// local users.
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
        var options = new FileStreamOptions
        {
            Mode = FileMode.Create,
            Access = FileAccess.Write,
            Share = FileShare.None
        };
        if (!OperatingSystem.IsWindows())
            options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(tmp, options))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
        {
            writer.Write(JsonSerializer.Serialize(map));
        }
        // A pre-existing file created by an older version may still be 0644;
        // the rename keeps the temp file's mode, so this covers both cases.
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
