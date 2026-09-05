namespace QuickProtect.Core.Models;

/// <summary>
/// The controller address as the user typed it, normalised into the two forms
/// the app actually needs: <see cref="Authority"/> (<c>host</c> or
/// <c>host:port</c>) for building <c>https://</c> API URLs, and
/// <see cref="PinKey"/> (the lower-cased host alone) as the single identity
/// under which the controller's certificate is pinned.
///
/// One identity matters because the controller is reached over two channels —
/// HTTPS for the API and RTSPS for video, where the stream URL the controller
/// hands back names <em>its own</em> idea of its address (usually the bare IP).
/// Both channels must consult the same pin, or a certificate change can be
/// trusted for one channel and stay rejected on the other with nothing in
/// Settings to fix it. Port of the macOS <c>ControllerAddress</c>.
///
/// Accepts the lenient forms people paste: an optional scheme, a port, a
/// trailing slash or path, surrounding whitespace, bracketed IPv6. Userinfo and
/// paths are dropped.
/// </summary>
public sealed record ControllerAddress(string Host, int? Port)
{
    public const int DefaultPort = 443;

    /// <summary>Parses the raw Settings text; null when no usable host is present.</summary>
    public static ControllerAddress? Parse(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        var withScheme = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(withScheme, UriKind.Absolute, out var uri)) return null;
        // IdnHost strips IPv6 brackets and normalises IDN names.
        var host = uri.IdnHost.ToLowerInvariant();
        if (host.Length == 0) return null;
        int? port = uri.IsDefaultPort || uri.Port == DefaultPort ? null : uri.Port;
        return new ControllerAddress(host, port);
    }

    /// <summary>Identity used for certificate pinning: the host alone.</summary>
    public string PinKey => Host;

    /// <summary><c>host</c> or <c>host:port</c>, IPv6 literals bracketed.</summary>
    public string Authority
    {
        get
        {
            var h = Host.Contains(':') ? "[" + Host + "]" : Host;
            return Port is { } p ? $"{h}:{p}" : h;
        }
    }

    public string HttpsBase => "https://" + Authority;
}
