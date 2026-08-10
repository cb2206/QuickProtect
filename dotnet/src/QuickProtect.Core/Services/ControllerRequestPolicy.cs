namespace QuickProtect.Core.Services;

/// <summary>
/// Pure request-policy decisions for talking to the Protect controller, whose
/// rate limiter allows 10 requests per second. Kept free of HttpClient and
/// service state so the rules are unit-testable in isolation (port of the
/// macOS <c>ControllerRequestPolicy</c>).
/// </summary>
public static class ControllerRequestPolicy
{
    /// <summary>
    /// Minimum interval between automatic camera-list fetches. Reopening the
    /// panel within this window reuses the current list instead of hitting the
    /// controller again; user-initiated refreshes bypass it.
    /// </summary>
    public static readonly TimeSpan FetchInterval = TimeSpan.FromSeconds(3);

    /// <summary>
    /// Minimum interval between PTZ-flag enrichments. Enrichment costs two
    /// extra requests per fetch — one of them a login the controller also
    /// audit-logs — and PTZ capabilities rarely change.
    /// </summary>
    public static readonly TimeSpan PtzEnrichInterval = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Whether an automatic fetch may be skipped because the last successful
    /// one is fresher than <paramref name="interval"/>.
    /// </summary>
    public static bool ShouldSkipFetch(DateTime? lastSuccess, DateTime now, TimeSpan? interval = null)
        => lastSuccess is { } last && now - last < (interval ?? FetchInterval);

    /// <summary>When and with which credentials PTZ flags were last enriched.</summary>
    public sealed record PtzEnrichRecord(DateTime At, string Username, string Password);

    /// <summary>
    /// Whether PTZ enrichment may be skipped: same credentials as last time and
    /// enriched recently. Credential changes always re-enrich so the Settings
    /// PTZ status reflects what the user just typed.
    /// </summary>
    public static bool ShouldSkipPtzEnrich(PtzEnrichRecord? last, string username, string password,
                                           DateTime now, TimeSpan? interval = null)
        => last is { } l && l.Username == username && l.Password == password
           && now - l.At < (interval ?? PtzEnrichInterval);

    /// <summary>
    /// Whether a failed stream-creation POST should abort the quality-fallback
    /// ladder instead of trying the next tier. On 429 or a server error the
    /// tier isn't the problem — retrying other tiers just multiplies requests
    /// against the limiter (up to 3× per camera).
    /// </summary>
    public static bool AbortsQualityLadder(int httpStatus)
        => httpStatus == 429 || httpStatus >= 500;
}
