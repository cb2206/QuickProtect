using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace QuickProtect.Core.Services;

/// <summary>
/// Certificate policy for the UniFi controller — a faithful port of the macOS
/// <c>CertificateTrust</c>.
///
/// Most controllers present a self-signed certificate, so default system trust
/// fails. Instead of blindly accepting any cert, the controller's public key is
/// pinned on first sight and mismatches are rejected thereafter (trust on first
/// use). Order of evaluation per connection:
/// <list type="number">
///   <item>System trust: a certificate the OS already trusts for the host it was
///   contacted under is accepted outright and not pinned.</item>
///   <item>No pin stored → record the key's fingerprint, accept.</item>
///   <item>Same key → accept.</item>
///   <item>Different key → reject and stash the candidate as "pending" so the
///   user can review both fingerprints in Settings and re-pin.</item>
/// </list>
/// Pins are keyed by <see cref="Models.ControllerAddress.PinKey"/> — one identity
/// shared by the HTTPS API and the RTSPS tunnel — and live in
/// <see cref="IPreferences"/> (a fingerprint is not a secret). The first
/// connection is inherently unverified; that limitation is documented in the
/// privacy policy.
/// </summary>
public sealed class CertificateTrust
{
    private readonly IPreferences _prefs;
    private const string PinnedPrefix = "qp.pinnedCert.";
    private const string PendingPrefix = "qp.pendingCert.";

    public CertificateTrust(IPreferences prefs) => _prefs = prefs;

    /// <summary>
    /// Raised (on the evaluating thread) when a connection was rejected because
    /// the controller's key changed. Hosts surface it in the UI; the RTSPS tunnel
    /// has no other channel back to the user.
    /// </summary>
    public event Action<string>? Rejected;

    private static string PinnedKey(string host) => PinnedPrefix + host;
    private static string PendingKey(string host) => PendingPrefix + host;

    public string? Pinned(string host) => _prefs.GetString(PinnedKey(host));
    public string? Pending(string host) => _prefs.GetString(PendingKey(host));

    private void SetPinned(string host, string? fp)
    {
        if (fp == null) _prefs.Remove(PinnedKey(host)); else _prefs.SetString(PinnedKey(host), fp);
    }

    private void SetPending(string host, string? fp)
    {
        if (fp == null) _prefs.Remove(PendingKey(host)); else _prefs.SetString(PendingKey(host), fp);
    }

    /// <summary>
    /// SHA-256 of the leaf certificate's DER SubjectPublicKeyInfo, lower-case
    /// hex. Pinning the key (not the whole cert) means a renewed certificate with
    /// the same key still validates. Matches the macOS app and
    /// <c>openssl x509 -pubkey | openssl pkey -pubin -outform DER | sha256sum</c>.
    /// </summary>
    public static string Fingerprint(X509Certificate2 cert)
    {
        var spki = cert.PublicKey.ExportSubjectPublicKeyInfo();
        return Convert.ToHexString(SHA256.HashData(spki)).ToLowerInvariant();
    }

    /// <summary>Groups a hex fingerprint into colon-separated byte pairs for display.</summary>
    public static string DisplayFingerprint(string hex)
        => string.Join(':', Enumerable.Range(0, (hex.Length + 1) / 2)
            .Select(i => hex.Substring(i * 2, Math.Min(2, hex.Length - i * 2))));

    /// <summary>
    /// Evaluate a leaf certificate for the controller identified by
    /// <paramref name="pinKey"/>. <paramref name="policyErrors"/> is the
    /// system-trust verdict for the host the socket was opened to; when the OS
    /// already trusts the chain the certificate is accepted without pinning.
    /// </summary>
    public bool Evaluate(string pinKey, X509Certificate2 leaf, SslPolicyErrors policyErrors)
    {
        if (policyErrors == SslPolicyErrors.None) return true;
        return Evaluate(pinKey, Fingerprint(leaf));
    }

    /// <summary>Evaluate an already-computed fingerprint. Shared decision point.</summary>
    public bool Evaluate(string host, string fingerprint)
    {
        var pinned = Pinned(host);
        if (pinned == null)
        {
            // Trust on first use.
            SetPinned(host, fingerprint);
            SetPending(host, null);
            return true;
        }
        if (pinned == fingerprint)
        {
            if (Pending(host) != null) SetPending(host, null);
            return true;
        }
        // Mismatch: remember the candidate so the user can choose to trust it.
        SetPending(host, fingerprint);
        Rejected?.Invoke(host);
        return false;
    }

    /// <summary>Every host with a changed certificate awaiting the user's decision.</summary>
    public IReadOnlyList<(string Host, string Fingerprint)> AllPending()
        => _prefs.Keys
            .Where(k => k.StartsWith(PendingPrefix, StringComparison.Ordinal))
            .Select(k => (Host: k[PendingPrefix.Length..], Fingerprint: _prefs.GetString(k)))
            .Where(p => p.Fingerprint != null)
            .Select(p => (p.Host, p.Fingerprint!))
            .OrderBy(p => p.Host, StringComparer.Ordinal)
            .ToList();

    /// <summary>Promote a pending (changed) certificate to the trusted pin (Settings action).</summary>
    public void TrustPending(string host)
    {
        var candidate = Pending(host);
        if (candidate == null) return;
        SetPinned(host, candidate);
        SetPending(host, null);
    }
}
