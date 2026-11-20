using System.Diagnostics;
using System.Text.Json;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;
using static QuickProtect.Core.Tests.FakeProtectConsole;

namespace QuickProtect.Core.Tests;

/// <summary>
/// The classic (cookie-auth) API against a scripted console: login and the
/// session it captures, PTZ continuous moves, and re-login on an expired session.
/// </summary>
public class ClassicLoginAndPtzTests
{
    [Fact]
    public async Task Login_captures_the_session_that_PTZ_moves_carry()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService(username: "ptz", password: "s3cret");
        using var disposeService = service;

        Assert.True(await service.ClassicLoginAsync());
        Assert.True(service.IsClassicLoggedIn);

        var login = Assert.Single(console.Controller.To(Login));
        using (var body = JsonDocument.Parse(login.Body))
        {
            Assert.Equal("ptz", body.RootElement.GetProperty("username").GetString());
            Assert.Equal("s3cret", body.RootElement.GetProperty("password").GetString());
        }

        service.PtzSetAxes("cam1", pan: 0.5);
        var move = (await console.Controller.WaitFor(Move("cam1")))[0];
        Assert.Equal("csrf-1", move.Header("X-CSRF-Token"));
        Assert.Equal("TOKEN=tok-1", move.Header("Cookie"));
        Assert.Equal((500, 0, 0), Velocities(move));
        // Already signed in: the move didn't cost another (audit-logged) login.
        Assert.Single(console.Controller.To(Login));
    }

    [Fact]
    public async Task A_second_login_sends_no_session_cookie()
    {
        // The controller's CSRF guard rejects a login POST that carries a
        // session cookie with 403, which would break every re-login.
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        Assert.True(await service.ClassicLoginAsync());
        Assert.True(await service.ClassicLoginAsync());

        var logins = console.Controller.To(Login);
        Assert.Equal(2, logins.Count);
        Assert.All(logins, l => Assert.Null(l.Header("Cookie")));
        Assert.All(logins, l => Assert.Null(l.Header("X-CSRF-Token")));
    }

    [Fact]
    public async Task Without_an_account_no_classic_request_is_made()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService(username: "", password: "");
        using var disposeService = service;

        Assert.False(await service.ClassicLoginAsync());
        await service.FetchCamerasAsync(forced: true);

        Assert.Equal(3, service.Cameras.Count);
        Assert.All(service.Cameras, c => Assert.False(c.IsPtz));
        Assert.Equal(new[] { IntegrationCameras }, console.Controller.Requests.Select(r => r.Route));
    }

    [Fact]
    public async Task A_rejected_PTZ_login_is_a_toast_not_a_grid_error()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == Login ? new FakeResponse(401, """{"error":"bad credentials"}""") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        service.PtzSetAxes("cam1", pan: 1);
        await WaitUntil(service, () => service.PtzErrorMessage != null);

        Assert.Equal("PTZ unavailable — check the username and password in Settings.", service.PtzErrorMessage);
        Assert.Null(service.ErrorMessage);
        Assert.False(service.IsClassicLoggedIn);
        Assert.Empty(console.Controller.To(Move("cam1")));
    }

    [Fact]
    public async Task Axes_combine_and_unchanged_commands_are_not_resent()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        service.PtzSetAxes("cam1", pan: 0.5);
        service.PtzSetAxes("cam1", pan: 0.5);   // same velocity: nothing to send
        service.PtzSetAxes("cam1", zoom: 1);    // zoom while panning keeps the pan
        service.PtzStopAll("cam1");
        service.PtzStopAll("cam1");             // already stopped
        service.PtzSetAxes("cam1", tilt: -1);

        var moves = await console.Controller.WaitFor(Move("cam1"), count: 4);
        Assert.Equal(new[] { (500, 0, 0), (500, 0, 1000), (0, 0, 0), (0, -1000, 0) },
                     moves.Select(Velocities));
        // The commands run in order on one chain, so the last move arriving
        // means the skipped ones were already decided.
        Assert.Equal(4, console.Controller.To(Move("cam1")).Count);
        Assert.Single(console.Controller.To(Login));
    }

    [Fact]
    public async Task A_quick_tap_still_moves_for_the_minimum_burst()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        var clock = Stopwatch.StartNew();
        service.PtzSetAxes("cam1", pan: 1);
        service.PtzSetAxes("cam1", pan: 0);  // released at once

        var moves = await console.Controller.WaitFor(Move("cam1"), count: 2);
        var elapsed = clock.Elapsed;
        Assert.Equal((1000, 0, 0), Velocities(moves[0]));
        Assert.Equal((0, 0, 0), Velocities(moves[1]));
        // Small tolerance for timer granularity; the stop must not come early.
        Assert.True(elapsed >= PtzBurstTimer.MinBurst - TimeSpan.FromMilliseconds(30),
                    $"stop arrived after {elapsed.TotalMilliseconds} ms");
    }

    [Fact]
    public async Task A_move_on_an_expired_session_logs_in_again_and_is_resent()
    {
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            // The first move finds the session expired.
            Override = r => r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 1
                ? new FakeResponse(401, """{"error":"Unauthorized"}""")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        // One press, no further input: the pan must still reach the camera.
        service.PtzSetAxes("cam1", pan: 1);
        var sent = await console.Controller.WaitFor(Move("cam1"), count: 2);

        Assert.Equal(2, console.Controller.To(Login).Count);
        Assert.Equal("TOKEN=tok-1", sent[0].Header("Cookie"));
        Assert.Equal("TOKEN=tok-2", sent[1].Header("Cookie"));
        Assert.Equal("csrf-2", sent[1].Header("X-CSRF-Token"));
        Assert.Equal((1000, 0, 0), Velocities(sent[1]));
        Assert.True(service.IsClassicLoggedIn);
    }

    [Fact]
    public async Task A_move_rejected_again_after_the_fresh_login_is_not_retried_further()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == Move("cam1") ? new FakeResponse(401, "") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 2);
        await WaitUntil(service, () => !service.IsClassicLoggedIn);
        // Give a runaway retry loop time to show itself.
        await Task.Delay(300);

        Assert.Equal(2, console.Controller.To(Move("cam1")).Count);
        Assert.Equal(2, console.Controller.To(Login).Count);
    }

    [Fact]
    public async Task A_package_snapshot_on_an_expired_session_logs_in_once_and_retries()
    {
        var snapshots = 0;
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == PackageSnapshot("cam3")
                ? Interlocked.Increment(ref snapshots) == 1
                    ? new FakeResponse(401, "")
                    : new FakeResponse(200, "JPEG", "image/jpeg")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        var doorbell = new Camera
        {
            Id = "cam3",
            Name = "Door",
            State = "CONNECTED",
            Secondary = new Camera.SecondaryLens("package", "Package Camera")
        };

        var jpeg = await service.FetchPackageSnapshotAsync(doorbell);

        Assert.Equal("JPEG"u8.ToArray(), jpeg);
        Assert.Equal(2, console.Controller.To(Login).Count);
        var requests = console.Controller.To(PackageSnapshot("cam3"));
        Assert.Equal(new[] { "TOKEN=tok-1", "TOKEN=tok-2" }, requests.Select(r => r.Header("Cookie")));
    }

    [Fact]
    public async Task Other_package_snapshot_failures_do_not_log_in_again()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == PackageSnapshot("cam3") ? new FakeResponse(500, "") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        var doorbell = new Camera
        {
            Id = "cam3",
            Name = "Door",
            State = "CONNECTED",
            Secondary = new Camera.SecondaryLens("package", "Package Camera")
        };

        Assert.Null(await service.FetchPackageSnapshotAsync(doorbell));
        Assert.Single(console.Controller.To(Login));
        Assert.Single(console.Controller.To(PackageSnapshot("cam3")));
    }
}

/// <summary>PTZ capability flags from the classic API, merged onto the Integration API's camera list.</summary>
public class PtzEnrichmentTests
{
    [Fact]
    public async Task A_fetch_with_an_account_marks_PTZ_and_zoom_cameras()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync(forced: true);

        Assert.Null(service.ErrorMessage);
        var byId = service.Cameras.ToDictionary(c => c.Id);
        Assert.True(byId["cam1"].IsPtz);
        Assert.False(byId["cam1"].CanZoom);
        Assert.True(byId["cam2"].IsPtz, "an optical zoom counts as PTZ (the zoom pill)");
        Assert.True(byId["cam2"].CanZoom);
        Assert.False(byId["cam3"].IsPtz);
        Assert.False(byId["cam3"].CanZoom);
        // The classic list was read with the session the login just captured.
        Assert.Equal("TOKEN=tok-1", Assert.Single(console.Controller.To(ClassicCameras)).Header("Cookie"));
    }

    [Fact]
    public async Task An_empty_classic_list_keeps_known_flags_but_a_real_answer_clears_them()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;
        await service.FetchCamerasAsync(forced: true);
        Assert.True(service.Cameras.Single(c => c.Id == "cam1").IsPtz);

        // A transient empty reply must not strip PTZ from every camera...
        console.ClassicBody = "[]";
        await service.FetchCamerasAsync(forced: true);
        Assert.True(service.Cameras.Single(c => c.Id == "cam1").IsPtz);

        // ...but a classic list that no longer flags cam1 is the authority.
        console.ClassicBody = """[{"id":"cam1","name":"Drive","featureFlags":{}}]""";
        await service.FetchCamerasAsync(forced: true);
        Assert.False(service.Cameras.Single(c => c.Id == "cam1").IsPtz);
        Assert.Equal(3, console.Controller.To(Login).Count);
    }

    [Fact]
    public async Task A_failed_enrichment_leaves_the_camera_list_usable()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == ClassicCameras ? new FakeResponse(500, "oops") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync(forced: true);

        Assert.Null(service.ErrorMessage);
        Assert.Null(service.PtzErrorMessage);
        Assert.Equal(3, service.Cameras.Count);
        Assert.All(service.Cameras, c => Assert.False(c.IsPtz));
    }

    [Fact]
    public async Task A_forced_refresh_enriches_again_inside_the_throttle_window()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync();
        await service.FetchCamerasAsync(forced: true);

        Assert.Equal(2, console.Controller.To(IntegrationCameras).Count);
        Assert.Equal(2, console.Controller.To(Login).Count);
    }
}

// The throttle tests wait out the automatic-fetch interval (3 s), so each sits
// in its own class: xUnit runs classes in parallel.

/// <summary>Automatic refreshes inside the PTZ throttle window skip the login.</summary>
public class PtzEnrichmentThrottleTests
{
    [Fact]
    public async Task An_automatic_refresh_inside_the_window_reuses_the_flags_without_a_login()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync();
        Assert.Single(console.Controller.To(Login));

        await Task.Delay(ControllerRequestPolicy.FetchInterval + TimeSpan.FromMilliseconds(300));
        await service.FetchCamerasAsync();

        Assert.Equal(2, console.Controller.To(IntegrationCameras).Count);
        Assert.Single(console.Controller.To(Login));
        // The fresh (flagless) list kept cam1's PTZ flag from the last enrichment.
        Assert.True(service.Cameras.Single(c => c.Id == "cam1").IsPtz);
    }
}

/// <summary>New credentials bypass the PTZ throttle.</summary>
public class PtzEnrichmentCredentialChangeTests
{
    [Fact]
    public async Task Changed_credentials_enrich_again_on_the_next_automatic_refresh()
    {
        await using var console = new FakeProtectConsole();
        var (service, site) = console.NewService(password: "old");
        using var disposeService = service;

        await service.FetchCamerasAsync();
        site.Password = "new";
        await Task.Delay(ControllerRequestPolicy.FetchInterval + TimeSpan.FromMilliseconds(300));
        await service.FetchCamerasAsync();

        var passwords = console.Controller.To(Login)
            .Select(l => JsonBodies.PropertyOf(l.Body, "password"));
        Assert.Equal(new[] { "old", "new" }, passwords);
    }
}

/// <summary>Only a successful enrichment arms the PTZ throttle.</summary>
public class PtzEnrichmentFailureThrottleTests
{
    [Fact]
    public async Task A_rate_limited_login_is_retried_on_the_next_automatic_refresh()
    {
        var logins = 0;
        await using var console = new FakeProtectConsole
        {
            // The panel-open burst hits the limiter on the first login.
            Override = r => r.Route == Login && Interlocked.Increment(ref logins) == 1
                ? new FakeResponse(429, """{"error":"Too many requests"}""")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync();
        Assert.Null(service.ErrorMessage);
        Assert.False(service.Cameras.Single(c => c.Id == "cam1").IsPtz);

        await Task.Delay(ControllerRequestPolicy.FetchInterval + TimeSpan.FromMilliseconds(300));
        await service.FetchCamerasAsync();

        Assert.Equal(2, console.Controller.To(Login).Count);
        Assert.True(service.Cameras.Single(c => c.Id == "cam1").IsPtz);
    }
}

/// <summary>How controller HTTP errors reach the panel, and which requests they cost.</summary>
public class ControllerHttpErrorTests
{
    [Theory]
    [InlineData(401, ControllerErrors.ApiKeyRejected)]
    [InlineData(403, ControllerErrors.ApiKeyRejected)]
    [InlineData(500, ControllerErrors.ServerError)]
    [InlineData(503, ControllerErrors.ServerError)]
    public async Task A_failed_camera_list_shows_its_error_and_skips_PTZ_enrichment(int status, string message)
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == IntegrationCameras ? new FakeResponse(status, """{"error":"x"}""") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        await service.FetchCamerasAsync(forced: true);

        Assert.Equal(message, service.ErrorMessage);
        Assert.Empty(service.Cameras);
        Assert.False(service.IsLoading);
        Assert.Empty(console.Controller.To(Login));
        Assert.Single(console.Controller.To(IntegrationCameras));
    }

    [Fact]
    public async Task A_single_429_on_the_camera_list_is_retried_silently()
    {
        var lists = 0;
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == IntegrationCameras && Interlocked.Increment(ref lists) == 1
                ? new FakeResponse(429, """{"error":"Too many requests"}""")
                : null
        };
        var (service, _) = console.NewService(username: "", password: "");
        using var disposeService = service;

        await service.FetchCamerasAsync(forced: true);

        Assert.Null(service.ErrorMessage);
        Assert.Equal(3, service.Cameras.Count);
        Assert.Equal(2, console.Controller.To(IntegrationCameras).Count);
    }

    [Fact]
    public async Task A_persistent_429_reports_a_busy_controller_after_one_retry()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == IntegrationCameras ? new FakeResponse(429, "{}") : null
        };
        var (service, _) = console.NewService(username: "", password: "");
        using var disposeService = service;

        await service.FetchCamerasAsync(forced: true);

        Assert.Equal(ControllerErrors.Busy, service.ErrorMessage);
        Assert.Equal(2, console.Controller.To(IntegrationCameras).Count);
    }

    [Theory]
    [InlineData(429)]
    [InlineData(500)]
    public async Task Rate_limiting_or_a_server_error_aborts_the_stream_quality_ladder(int status)
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == CreateStream("cam1") ? new FakeResponse(status, "{}") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        var result = await service.CreateRtspStreamUrlAsync(new Camera { Id = "cam1", Name = "Drive" }, "high");

        Assert.Null(result);
        Assert.Single(console.Controller.To(CreateStream("cam1")));
    }

    [Fact]
    public async Task An_unavailable_quality_falls_back_to_the_next_tier()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route != CreateStream("cam1") ? null
                : r.Body.Contains("\"high\"")
                    ? new FakeResponse(400, """{"error":"quality not available"}""")
                    : FakeResponse.Json("""{"medium":"rtsps://10.0.0.1:7441/abc123?enableSrtp"}""")
        };
        var (service, _) = console.NewService();
        using var disposeService = service;

        var result = await service.CreateRtspStreamUrlAsync(new Camera { Id = "cam1", Name = "Drive" }, "high");

        Assert.Equal(("rtsps://10.0.0.1:7441/abc123", "medium"), result);
        var requested = console.Controller.To(CreateStream("cam1"))
            .Select(r => JsonBodies.FirstOf(r.Body, "qualities"));
        Assert.Equal(new[] { "high", "medium" }, requested);
    }
}

/// <summary>Reads one value from a recorded JSON request body, disposing the document.</summary>
internal static class JsonBodies
{
    public static string? PropertyOf(string json, string name)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.GetProperty(name).GetString();
    }

    public static string? FirstOf(string json, string arrayName)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.GetProperty(arrayName)[0].GetString();
    }
}
