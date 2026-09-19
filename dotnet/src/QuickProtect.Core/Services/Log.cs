using System.Diagnostics;

namespace QuickProtect.Core.Services;

/// <summary>Minimal diagnostic logger (stand-in for the macOS app's RTSPClient.log).</summary>
public static class Log
{
    public static void Line(string message)
    {
        Debug.WriteLine(message);
        Console.WriteLine(message);
    }

    /// <summary>
    /// Scheme, host and port only. The path of a stream URL is a bearer token for
    /// live video and must never reach a log (stdout ends up in the journal on
    /// Linux).
    /// </summary>
    public static string RedactUrl(string? url)
    {
        if (url == null) return "nil";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return "<unparseable url>";
        var port = uri.IsDefaultPort ? "" : $":{uri.Port}";
        return $"{uri.Scheme}://{uri.Host}{port}/…";
    }
}
