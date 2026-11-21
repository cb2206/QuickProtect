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
    public async Task A_move_the_controller_keeps_rejecting_is_tried_a_bounded_number_of_times()
    {
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == Move("cam1") ? new FakeResponse(401, "") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        // Send, resend after a re-login; one delayed retry, which logs in again
        // and gets its own single resend (a console restart can 401 it too).
        await console.Controller.WaitFor(Move("cam1"), count: 4);
        // Give a runaway retry loop time to show itself.
        await Task.Delay(PtzSettle);

        Assert.Equal(4, console.Controller.To(Move("cam1")).Count);
        Assert.Equal(4, console.Controller.To(Login).Count);
    }

    [Fact]
    public async Task A_failed_stop_is_retried_once_on_its_own()
    {
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            // The release's stop hits a server error; the controller then recovers.
            Override = r => r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 2
                ? new FakeResponse(500, "")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 1);
        // No further input after the release: the stop must still arrive.
        service.PtzSetAxes("cam1", pan: 0);
        var sent = await console.Controller.WaitFor(Move("cam1"), count: 3);

        Assert.Equal(new[] { (1000, 0, 0), (0, 0, 0), (0, 0, 0) }, sent.Select(Velocities));
        // Delivered now: a further stop is a duplicate and isn't sent.
        service.PtzStopAll("cam1");
        await Task.Delay(300);
        Assert.Equal(3, console.Controller.To(Move("cam1")).Count);
    }

    [Fact]
    public async Task A_stop_whose_login_fails_is_retried_on_its_own()
    {
        var loginsFail = false;
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            Override = r =>
                r.Route == Login && Volatile.Read(ref loginsFail) ? new FakeResponse(401, "")
                // The tilt press finds the session expired (and the re-login fails).
                : r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 2 ? new FakeResponse(401, "")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 1);
        Volatile.Write(ref loginsFail, true);
        service.PtzSetAxes("cam1", tilt: 1);
        await WaitUntil(service, () => service.PtzErrorMessage != null);

        // The camera is still panning. The stop's own login fails too...
        var loginsBeforeStop = console.Controller.To(Login).Count;
        service.PtzStopAll("cam1");
        await console.Controller.WaitFor(Login, count: loginsBeforeStop + 1);
        Assert.DoesNotContain(console.Controller.To(Move("cam1")), m => Velocities(m) == (0, 0, 0));
        // ...then the console recovers, and with nothing else pressed the stop arrives.
        Volatile.Write(ref loginsFail, false);
        await WaitForLastMove(console, (0, 0, 0));
    }

    [Fact]
    public async Task A_stop_failing_late_in_an_outage_is_retried_after_it()
    {
        var failing = false;
        var stopsDelivered = 0;
        await using var console = new FakeProtectConsole
        {
            Override = r =>
            {
                if (r.Route != Move("cam1")) return null;
                if (Volatile.Read(ref failing)) return new FakeResponse(500, "");
                if (Velocities(r) == (0, 0, 0)) Interlocked.Increment(ref stopsDelivered);
                return null;
            }
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 1);
        // A 1.3 s outage: the tilt press fails at its start, the stop near its end.
        Volatile.Write(ref failing, true);
        service.PtzSetAxes("cam1", tilt: 1);
        await Task.Delay(900);
        service.PtzStopAll("cam1");
        await Task.Delay(400);
        Volatile.Write(ref failing, false);

        await WaitForLastMove(console, (0, 0, 0));
        Assert.Equal(1, Volatile.Read(ref stopsDelivered));
    }

    [Fact]
    public async Task A_stop_for_another_camera_does_not_abandon_a_failed_one()
    {
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            // cam1's stop hits a server error.
            Override = r => r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 2
                ? new FakeResponse(500, "")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 1);
        service.PtzStopAll("cam1");
        service.PtzStopAll("cam2");

        // The failed stop, then its retry.
        var sent = await console.Controller.WaitFor(Move("cam1"), count: 3);
        Assert.Equal(new[] { (1000, 0, 0), (0, 0, 0), (0, 0, 0) }, sent.Select(Velocities));
        // cam2 never moved: its stop is a no-op.
        Assert.Empty(console.Controller.To(Move("cam2")));
    }

    [Fact]
    public async Task Stopping_a_camera_that_never_moved_sends_nothing()
    {
        await using var console = new FakeProtectConsole();
        var (service, _) = console.NewService();
        using var disposeService = service;

        // Focus exit calls this for every camera.
        service.PtzStopAll("cam1");
        await Task.Delay(PtzSettle);

        Assert.Empty(console.Controller.To(Move("cam1")));
        Assert.Empty(console.Controller.To(Login));
        Assert.Null(service.PtzErrorMessage);
    }

    [Fact]
    public async Task Held_axes_survive_a_failed_command()
    {
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            // The tilt press fails; pan is still held.
            Override = r => r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 2
                ? new FakeResponse(500, "")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 1);
        service.PtzSetAxes("cam1", tilt: 1);
        await console.Controller.WaitFor(Move("cam1"), count: 2);
        service.PtzSetAxes("cam1", zoom: 1);

        // Pan is still held: the zoom press keeps it (and the failed tilt).
        await WaitForLastMove(console, (1000, 1000, 1000));
    }

    [Fact]
    public async Task A_forbidden_move_does_not_log_in_again()
    {
        // An account without PTZ permission: every move is 403.
        await using var console = new FakeProtectConsole
        {
            Override = r => r.Route == Move("cam1") ? new FakeResponse(403, "") : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        service.PtzSetAxes("cam1", pan: 1);
        service.PtzSetAxes("cam1", pan: 0);
        service.PtzSetAxes("cam1", tilt: 1);
        // Press, release, press, and one retry for the camera (retries are
        // coalesced per camera while one is pending).
        await console.Controller.WaitFor(Move("cam1"), count: 4);
        await Task.Delay(PtzSettle);
        Assert.Equal(4, console.Controller.To(Move("cam1")).Count);

        Assert.Single(console.Controller.To(Login));
        Assert.True(service.IsClassicLoggedIn);
    }

    [Fact]
    public async Task A_failed_relogin_during_a_move_shows_the_ptz_toast_and_the_next_press_is_sent()
    {
        var loginsFail = false;
        var moves = 0;
        await using var console = new FakeProtectConsole
        {
            Override = r =>
                r.Route == Login && Volatile.Read(ref loginsFail) ? new FakeResponse(401, "")
                : r.Route == Move("cam1") && Interlocked.Increment(ref moves) == 1 ? new FakeResponse(401, "")
                : null
        };
        var (service, _) = console.NewService();
        using var disposeService = service;
        Assert.True(await service.ClassicLoginAsync());

        Volatile.Write(ref loginsFail, true);
        service.PtzSetAxes("cam1", pan: 1);
        await WaitUntil(service, () => service.PtzErrorMessage != null);
        Assert.Equal("PTZ unavailable — check the username and password in Settings.", service.PtzErrorMessage);

        // Credentials work again: pressing the same direction must not be
        // dropped as a duplicate of the move that never arrived.
        Volatile.Write(ref loginsFail, false);
        service.PtzSetAxes("cam1", pan: 0);
        service.PtzSetAxes("cam1", pan: 1);
        var last = await WaitForLastMove(console, (1000, 0, 0));
        Assert.NotEqual("TOKEN=tok-1", last.Header("Cookie"));
        Assert.True(service.IsClassicLoggedIn);
    }

    /// <summary>Longer than <see cref="ProtectService.PtzRetryDelay"/>, so any retry has happened.</summary>
    private static readonly int PtzSettle = (int)ProtectService.PtzRetryDelay.TotalMilliseconds + 500;

    /// <summary>
    /// Waits until the controller's latest move carries <paramref name="expected"/>
    /// and nothing follows it for the retry delay (the PTZ state has settled).
    /// </summary>
    private static async Task<FakeRequest> WaitForLastMove(FakeProtectConsole console, (int, int, int) expected)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline)
        {
            var moves = console.Controller.To(Move("cam1"));
            if (moves.Count > 0 && Velocities(moves[^1]) == expected)
            {
                await Task.Delay(PtzSettle);
                var after = console.Controller.To(Move("cam1"));
                if (after.Count == moves.Count) return after[^1];
                continue;
            }
            await Task.Delay(25);
        }
        var all = console.Controller.To(Move("cam1")).Select(Velocities);
        throw new Xunit.Sdk.XunitException($"last move never settled on {expected}; moves: {string.Join(" ", all)}");
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
