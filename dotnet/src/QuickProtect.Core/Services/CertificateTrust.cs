using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace QuickProtect.Core.Services;

/// <summary>
/// Trust-on-first-use (TOFU) certificate pinning for the UniFi controller.
/// UniFi controllers present a self-signed certificate, so default system trust
/// always fails. Instead of blindly accepting any cert, this pins the
/// controller's public key on first sight and rejects mismatches thereafter.
/// Pins live in <see cref="IPreferences"/> (a fingerprint is not a secret) — a
/// faithful port of the macOS <c>CertificateTrust</c>.
/// </summary>
public sealed class CertificateTrust
{
    private readonly IPreferences _prefs;

    public CertificateTrust(IPreferences prefs) => _prefs = prefs;

    private static string PinnedKey(string host) => $"qp.pinnedCert.{host}";
    private static string PendingKey(string host) => $"qp.pendingCert.{host}";

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
    /// SHA-256 of the leaf certificate's SubjectPublicKeyInfo, hex-encoded.
    /// Pinning the key (not the whole cert) means a renewed certificate with the
    /// same key still validates.
    /// </summary>
    public static string Fingerprint(X509Certificate2 cert)
    {
        var spki = cert.PublicKey.ExportSubjectPublicKeyInfo();
        return Convert.ToHexString(SHA256.HashData(spki)).ToLowerInvariant();
    }

    /// <summary>Evaluate a leaf certificate for <paramref name="host"/> under the TOFU policy.</summary>
    public bool Evaluate(string host, X509Certificate2 leaf) => Evaluate(host, Fingerprint(leaf));

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
        return false;
    }

    /// <summary>Promote a pending (changed) certificate to the trusted pin (Settings action).</summary>
    public void TrustPending(string host)
    {
        var candidate = Pending(host);
        if (candidate == null) return;
        SetPinned(host, candidate);
        SetPending(host, null);
    }
}
