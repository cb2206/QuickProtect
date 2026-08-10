using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Tests for the pure controller request-policy rules (fetch throttling, PTZ
/// enrichment throttling, quality-ladder abort) and the stream keep-alive
/// clamping — the port of the macOS ControllerRequestPolicyTests.
/// </summary>
public class ControllerRequestPolicyTests
{
    private static readonly DateTime Now = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);

    // MARK: - Fetch throttle

    [Fact]
    public void First_fetch_is_never_skipped()
        => Assert.False(ControllerRequestPolicy.ShouldSkipFetch(null, Now));

    [Fact]
    public void Fresh_fetch_is_skipped()
        => Assert.True(ControllerRequestPolicy.ShouldSkipFetch(Now.AddSeconds(-1), Now));

    [Fact]
    public void Stale_fetch_is_not_skipped()
        => Assert.False(ControllerRequestPolicy.ShouldSkipFetch(
            Now - ControllerRequestPolicy.FetchInterval, Now));

    // MARK: - PTZ enrichment throttle

    private static ControllerRequestPolicy.PtzEnrichRecord Record(
        double agoSeconds, string username = "u", string password = "p")
        => new(Now.AddSeconds(-agoSeconds), username, password);

    [Fact]
    public void Ptz_enrich_runs_when_never_enriched()
        => Assert.False(ControllerRequestPolicy.ShouldSkipPtzEnrich(null, "u", "p", Now));

    [Fact]
    public void Ptz_enrich_skipped_when_recent_with_same_credentials()
        => Assert.True(ControllerRequestPolicy.ShouldSkipPtzEnrich(Record(10), "u", "p", Now));

    [Fact]
    public void Ptz_enrich_runs_when_credentials_changed()
        => Assert.False(ControllerRequestPolicy.ShouldSkipPtzEnrich(
            Record(10, password: "old"), "u", "new", Now));

    [Fact]
    public void Ptz_enrich_runs_again_after_interval()
        => Assert.False(ControllerRequestPolicy.ShouldSkipPtzEnrich(
            Record(ControllerRequestPolicy.PtzEnrichInterval.TotalSeconds), "u", "p", Now));

    // MARK: - Quality-ladder abort

    [Theory]
    [InlineData(429)]
    [InlineData(500)]
    [InlineData(503)]
    public void Rate_limit_and_server_errors_abort_ladder(int status)
        => Assert.True(ControllerRequestPolicy.AbortsQualityLadder(status));

    [Theory]
    [InlineData(400)]
    [InlineData(404)]
    public void Quality_errors_continue_ladder(int status)
        => Assert.False(ControllerRequestPolicy.AbortsQualityLadder(status));

    // MARK: - Keep-alive clamping

    [Theory]
    [InlineData(-5, 0)]
    [InlineData(0, 0)]
    [InlineData(10, 10)]
    [InlineData(600, 60)]
    public void Keep_alive_clamps_to_range(int value, int expected)
        => Assert.Equal(expected, AppSettings.ClampStreamKeepAlive(value));

    [Fact]
    public void Keep_alive_default_is_in_range()
        => Assert.Equal(AppSettings.StreamKeepAliveDefault,
            AppSettings.ClampStreamKeepAlive(AppSettings.StreamKeepAliveDefault));
}
