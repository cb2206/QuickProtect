using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;

namespace QuickProtect.Core.Services;

/// <summary>
/// Maps a failed controller request to a user-facing message. Returns the
/// English source text, which is also the localization catalog key: .NET's own
/// exception messages are English-only, so the raw text would never translate
/// (macOS gets translated <c>URLError</c> descriptions from the OS instead).
/// Unrecognized failures fall back to the exception message.
/// </summary>
public static class ControllerErrors
{
    public const string HostNotFound = "Can't find the controller. Check the IP address or hostname in Settings.";
    public const string ConnectionRefused = "The controller refused the connection. Check the IP address in Settings.";
    public const string Unreachable = "Can't reach the controller. Check that it's online and on the same network.";
    public const string TimedOut = "The controller didn't respond in time. Check that it's online and on the same network.";
    public const string SecureConnectionFailed = "A secure connection to the controller couldn't be established.";
    public const string InvalidAddress = "Invalid IP address or URL.";
    public const string ApiKeyRejected = "The controller rejected the API key. Check it in Settings.";
    public const string Busy = "The controller is busy. Try again in a moment.";
    public const string ServerError = "The controller reported an internal error. Try again later.";
    public const string UnexpectedResponse = "The controller returned an unexpected response.";
    public const string UnreadableResponse = "The controller sent a response QuickProtect couldn't read.";

    /// <summary>Every message <see cref="Describe"/> can return besides the raw fallback.</summary>
    public static readonly IReadOnlyList<string> All = new[]
    {
        HostNotFound, ConnectionRefused, Unreachable, TimedOut, SecureConnectionFailed, InvalidAddress,
        ApiKeyRejected, Busy, ServerError, UnexpectedResponse, UnreadableResponse
    };

    public static string Describe(Exception ex)
    {
        switch (ex)
        {
            case ProtectService.ApiException api:
                return api.StatusCode switch
                {
                    401 or 403 => ApiKeyRejected,
                    429 => Busy,
                    >= 500 => ServerError,
                    _ => UnexpectedResponse
                };
            case UriFormatException:
                return InvalidAddress;
            case JsonException:
                return UnreadableResponse;
            // HttpClient reports its own timeout as a cancellation (the caller's
            // cancellation is filtered out before a fetch error is applied).
            case TaskCanceledException or TimeoutException:
                return TimedOut;
        }

        if (Find<SocketException>(ex) is { } socket)
            return socket.SocketErrorCode switch
            {
                SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain => HostNotFound,
                SocketError.ConnectionRefused => ConnectionRefused,
                SocketError.TimedOut => TimedOut,
                _ => Unreachable
            };
        if (Find<AuthenticationException>(ex) != null) return SecureConnectionFailed;
        if (ex is HttpRequestException) return Unreachable;
        return ex.Message;
    }

    private static T? Find<T>(Exception ex) where T : Exception
    {
        for (Exception? e = ex; e != null; e = e.InnerException)
            if (e is T match) return match;
        return null;
    }
}
