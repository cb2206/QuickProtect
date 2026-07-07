using System.Text.Json;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

public class StreamQualityTests
{
    [Theory]
    [InlineData(StreamQuality.Auto, true, false, StreamQuality.High)]   // focus → high
    [InlineData(StreamQuality.Auto, false, true, StreamQuality.Medium)] // grid large → medium
    [InlineData(StreamQuality.Auto, false, false, StreamQuality.Low)]   // grid small → low
    [InlineData(StreamQuality.High, false, false, StreamQuality.High)]  // explicit passes through
    public void Resolve_matches_macOS_behavior(StreamQuality q, bool focused, bool large, StreamQuality expected)
        => Assert.Equal(expected, q.Resolve(focused, large));

    [Fact]
    public void ApiValue_maps_auto_to_medium()
    {
        Assert.Equal("medium", StreamQuality.Auto.ApiValue());
        Assert.Equal("high", StreamQuality.High.ApiValue());
    }

    [Fact]
    public void Rank_orders_low_below_high()
        => Assert.True(StreamQuality.Low.Rank() < StreamQuality.High.Rank());

    [Fact]
    public void FromRawValue_roundtrips()
        => Assert.Equal(StreamQuality.Medium, StreamQualityExtensions.FromRawValue("medium"));
}

public class CameraJsonTests
{
    [Fact]
    public void Parses_integration_api_camera()
    {
        const string json = """
        { "id": "abc", "name": "Front Door", "state": "CONNECTED", "hasPackageCamera": true }
        """;
        var cam = JsonSerializer.Deserialize<Camera>(json)!;
        Assert.Equal("abc", cam.Id);
        Assert.Equal("Front Door", cam.Name);
        Assert.True(cam.IsOnline);
        Assert.NotNull(cam.Secondary);
        Assert.Equal("package", cam.Secondary!.Quality);
    }

    [Fact]
    public void Parses_classic_api_feature_flags_for_ptz_and_zoom()
    {
        const string json = """
        { "id": "ptz1", "name": "PTZ", "state": "CONNECTED",
          "featureFlags": { "isPtz": false, "canOpticalZoom": false, "zoom": { "ratio": 4 } } }
        """;
        var cam = JsonSerializer.Deserialize<Camera>(json)!;
        // zoomRatio > 1 implies optical zoom, which the macOS port treats as PTZ-capable.
        Assert.True(cam.IsPtz);
        Assert.True(cam.CanZoom);
    }

    [Fact]
    public void Missing_fields_do_not_throw()
    {
        var cam = JsonSerializer.Deserialize<Camera>("""{ "id": "x", "name": "y" }""")!;
        Assert.Equal("UNKNOWN", cam.State);
        Assert.False(cam.IsOnline);
        Assert.Empty(cam.Channels);
    }

    [Fact]
    public void PrimaryRtspAlias_prefers_enabled_channel()
    {
        const string json = """
        { "id": "c", "name": "c", "channels": [
            { "id": 0, "name": "High", "rtspAlias": "aaa", "isRtspEnabled": false },
            { "id": 1, "name": "Low", "rtspAlias": "bbb", "isRtspEnabled": true } ] }
        """;
        var cam = JsonSerializer.Deserialize<Camera>(json)!;
        Assert.Equal("bbb", cam.PrimaryRtspAlias);
    }
}

public class PtzMappingTests
{
    [Theory]
    [InlineData(PtzDirection.Left, -1.0, null, null)]
    [InlineData(PtzDirection.Right, 1.0, null, null)]
    [InlineData(PtzDirection.Up, null, 1.0, null)]
    [InlineData(PtzDirection.Down, null, -1.0, null)]
    [InlineData(PtzDirection.ZoomIn, null, null, 1.0)]
    [InlineData(PtzDirection.ZoomOut, null, null, -1.0)]
    public void Press_maps_direction_to_axis(PtzDirection d, double? pan, double? tilt, double? zoom)
    {
        var a = PtzMapping.Press(d);
        Assert.Equal(pan, a.Pan);
        Assert.Equal(tilt, a.Tilt);
        Assert.Equal(zoom, a.Zoom);
    }

    [Theory]
    [InlineData(PtzDirection.Left, 0.0, null, null)]
    [InlineData(PtzDirection.Up, null, 0.0, null)]
    [InlineData(PtzDirection.ZoomOut, null, null, 0.0)]
    public void Release_zeros_only_its_axis(PtzDirection d, double? pan, double? tilt, double? zoom)
    {
        var a = PtzMapping.Release(d);
        Assert.Equal(pan, a.Pan);
        Assert.Equal(tilt, a.Tilt);
        Assert.Equal(zoom, a.Zoom);
    }
}

public class PtzBurstTimerTests
{
    private static readonly DateTime T0 = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void Quick_tap_release_is_postponed_to_min_burst()
    {
        var timer = new PtzBurstTimer();
        Assert.Equal(TimeSpan.Zero, timer.Update(pan: 1, null, null, T0));
        var delay = timer.Update(pan: 0, null, null, T0 + TimeSpan.FromMilliseconds(100));
        Assert.Equal(TimeSpan.FromMilliseconds(150), delay);
    }

    [Fact]
    public void Long_hold_release_sends_immediately()
    {
        var timer = new PtzBurstTimer();
        timer.Update(pan: 1, null, null, T0);
        Assert.Equal(TimeSpan.Zero, timer.Update(pan: 0, null, null, T0 + TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void Axes_track_independently_and_longest_delay_wins()
    {
        var timer = new PtzBurstTimer();
        timer.Update(pan: 1, null, null, T0);
        timer.Update(null, tilt: 1, null, T0 + TimeSpan.FromMilliseconds(200));
        // Release both 210ms after T0: pan needs 40ms more, tilt needs 240ms more.
        var delay = timer.Update(pan: 0, tilt: 0, null, T0 + TimeSpan.FromMilliseconds(210));
        Assert.Equal(TimeSpan.FromMilliseconds(240), delay);
    }

    [Fact]
    public void Press_never_delays_and_reset_clears_running_axes()
    {
        var timer = new PtzBurstTimer();
        Assert.Equal(TimeSpan.Zero, timer.Update(null, null, zoom: 1, T0));
        timer.Reset();
        // After reset the release has no recorded start, so no burst delay.
        Assert.Equal(TimeSpan.Zero, timer.Update(null, null, zoom: 0, T0 + TimeSpan.FromMilliseconds(10)));
    }
}

public class DigitalZoomTests
{
    [Fact]
    public void Starts_at_one_x_with_no_crop()
    {
        var z = new DigitalZoom();
        Assert.False(z.IsZoomed);
        Assert.Null(z.CropGeometry(1920, 1080));
    }

    [Fact]
    public void Zoom_clamps_to_range()
    {
        var z = new DigitalZoom();
        z.SetZoom(100);
        Assert.Equal(DigitalZoom.MaxZoom, z.Zoom);
        z.SetZoom(0.1);
        Assert.Equal(DigitalZoom.MinZoom, z.Zoom);
    }

    [Fact]
    public void Two_x_centered_crop_is_the_middle_quarter()
    {
        var z = new DigitalZoom();
        z.SetZoom(2);
        Assert.Equal("960x540+480+270", z.CropGeometry(1920, 1080));
    }

    [Fact]
    public void Pan_is_clamped_to_frame_edges()
    {
        var z = new DigitalZoom();
        z.SetZoom(2);
        z.Pan(-10, -10); // way past the top-left corner
        Assert.Equal("960x540+0+0", z.CropGeometry(1920, 1080));
        z.Pan(20, 20); // way past the bottom-right corner
        Assert.Equal("960x540+960+540", z.CropGeometry(1920, 1080));
    }

    [Fact]
    public void Zooming_back_out_recenters()
    {
        var z = new DigitalZoom();
        z.SetZoom(4);
        z.Pan(1, 1);
        z.SetZoom(1);
        Assert.False(z.IsZoomed);
        Assert.Equal(0.5, z.CenterX);
        Assert.Equal(0.5, z.CenterY);
    }

    [Fact]
    public void Pan_before_zoom_is_ignored()
    {
        var z = new DigitalZoom();
        z.Pan(0.5, 0.5);
        Assert.Equal(0.5, z.CenterX);
    }
}

public class PinnedWindowGeometryTests
{
    [Fact]
    public void DefaultSize_scales_width_to_aspect_ratio()
    {
        var s = PinnedWindowGeometry.DefaultSize(16.0 / 9.0, targetWidth: 360);
        Assert.Equal(360, s.Width);
        Assert.Equal(Math.Round(360 / (16.0 / 9.0)), s.Height); // 203
    }

    [Fact]
    public void DefaultSize_clamps_width_and_falls_back_for_bad_aspect()
    {
        Assert.Equal(PinnedWindowGeometry.MinWidth, PinnedWindowGeometry.DefaultSize(1.0, targetWidth: 10).Width);
        Assert.Equal(PinnedWindowGeometry.MaxWidth, PinnedWindowGeometry.DefaultSize(1.0, targetWidth: 9999).Width);
        var fb = PinnedWindowGeometry.DefaultSize(0); // non-positive aspect → 16:9 fallback
        Assert.Equal(Math.Round(fb.Width / PinnedWindowGeometry.FallbackAspect), fb.Height);
    }

    [Fact]
    public void Constrain_drives_height_from_width()
    {
        var s = PinnedWindowGeometry.Constrain(800, 2.0);
        Assert.Equal(800, s.Width);
        Assert.Equal(400, s.Height);
    }
}

public class SnapshotNamingTests
{
    [Fact]
    public void FileName_is_timestamped_and_sanitized()
    {
        // space → '-', '/' → '_' (any non-alphanumeric that isn't space/-/_).
        var name = SnapshotNaming.FileName("Front Door / Porch", new DateTime(2026, 6, 25, 14, 30, 5));
        Assert.Equal("QuickProtect_Front-Door-_-Porch_2026-06-25_14-30-05.png", name);
    }

    [Fact]
    public void FileName_falls_back_for_empty_name()
    {
        var name = SnapshotNaming.FileName("   ", new DateTime(2026, 1, 1, 0, 0, 0));
        Assert.StartsWith("QuickProtect_Camera_", name);
        Assert.EndsWith(".png", name);
    }

    [Fact]
    public void FileName_has_no_path_separators()
    {
        var name = SnapshotNaming.FileName("a/b\\c", new DateTime(2026, 1, 1, 0, 0, 0));
        Assert.DoesNotContain('/', name[..name.LastIndexOf('.')]);
        Assert.DoesNotContain('\\', name);
    }
}

public class VersionCompareTests
{
    [Theory]
    [InlineData("1.2.2", "1.2.1", true)]
    [InlineData("1.3.0", "1.2.9", true)]
    [InlineData("2.0.0", "1.9.9", true)]
    [InlineData("1.2.1", "1.2.1", false)]
    [InlineData("1.2.0", "1.2.1", false)]
    [InlineData("1.2", "1.2.0", false)]      // shorter == treated as trailing zeros
    [InlineData("1.2.1.1", "1.2.1", true)]   // extra component wins
    public void IsNewer_compares_components(string remote, string local, bool expected)
        => Assert.Equal(expected, VersionCompare.IsNewer(remote, local));
}

public class CertificateTrustTests
{
    private static CertificateTrust New() => new(new InMemoryPreferences());

    [Fact]
    public void First_use_pins_and_accepts()
        => Assert.True(New().Evaluate("10.0.0.1", "fingerprintA"));

    [Fact]
    public void Same_key_accepts_mismatch_rejects_then_trust_pending_promotes()
    {
        var t = New();
        Assert.True(t.Evaluate("h", "A"));   // TOFU
        Assert.True(t.Evaluate("h", "A"));   // same key
        Assert.False(t.Evaluate("h", "B"));  // changed key → reject
        Assert.Equal("B", t.Pending("h"));   // candidate stashed
        t.TrustPending("h");
        Assert.True(t.Evaluate("h", "B"));   // now accepted
        Assert.Null(t.Pending("h"));
    }
}

public class AppSettingsTests
{
    private static AppSettings New() => new(new InMemoryPreferences(), new InMemorySecretStore());

    [Fact]
    public void Secrets_go_through_secret_store_not_prefs()
    {
        var prefs = new InMemoryPreferences();
        var secrets = new InMemorySecretStore();
        var s = new AppSettings(prefs, secrets) { ApiKey = "supersecret" };
        Assert.Equal("supersecret", secrets.Get("unifi.apiKey"));
        Assert.Null(prefs.GetString("unifi.apiKey"));
    }

    [Fact]
    public void Per_camera_quality_override_falls_back_to_default()
    {
        var s = New();
        s.DefaultStreamQuality = StreamQuality.Low;
        Assert.Equal(StreamQuality.Low, s.EffectiveStreamQuality("cam1"));
        s.SetStreamQuality(StreamQuality.High, "cam1");
        Assert.Equal(StreamQuality.High, s.EffectiveStreamQuality("cam1"));
        Assert.Equal(StreamQuality.Low, s.EffectiveStreamQuality("other"));
    }

    [Fact]
    public void Hidden_and_order_apply_within_active_profile()
    {
        var s = New();
        var cams = new List<Camera>
        {
            new() { Id = "a", Name = "A", State = "CONNECTED" },
            new() { Id = "b", Name = "B", State = "CONNECTED" },
            new() { Id = "c", Name = "C", State = "CONNECTED" },
        };
        s.SetHidden(true, "b");
        Assert.Equal(new[] { "a", "c" }, s.VisibleCameras(cams).Select(c => c.Id));

        s.SetCameraOrder(new[] { "c", "a" });
        Assert.Equal(new[] { "c", "a" }, s.OrderedCameras(s.VisibleCameras(cams)).Select(c => c.Id));
    }

    [Fact]
    public void Profiles_isolate_layout_state()
    {
        var s = New();
        s.SetHidden(true, "cam1");           // hidden in Default
        var p2 = s.CreateProfile("Night");   // snapshots Default, then switches
        Assert.True(s.IsHidden("cam1"));     // copied into the new profile
        s.SetHidden(false, "cam1");          // unhide only in Night
        s.SwitchProfile(AppSettings.DefaultProfileId);
        Assert.True(s.IsHidden("cam1"));     // Default still hidden
        s.SwitchProfile(p2);
        Assert.False(s.IsHidden("cam1"));
    }

    [Fact]
    public void Pinned_camera_state_roundtrips()
    {
        var s = New();
        Assert.False(s.IsPinned("cam1"));
        s.SetPinned("cam1", (10, 20, 300, 200));
        Assert.True(s.IsPinned("cam1"));
        var state = s.PinnedCameras().Single(p => p.CameraId == "cam1");
        Assert.Equal(300, state.W);
        Assert.Equal(200, state.H);
        s.RemovePinned("cam1");
        Assert.False(s.IsPinned("cam1"));
    }

    [Fact]
    public void Legacy_plaintext_secret_migrates_into_secret_store()
    {
        var prefs = new InMemoryPreferences();
        var secrets = new InMemorySecretStore();
        prefs.SetString("unifi.apiKey", "legacyKey"); // simulate pre-upgrade plaintext
        var s = new AppSettings(prefs, secrets);
        Assert.Equal("legacyKey", s.ApiKey);
        Assert.Equal("legacyKey", secrets.Get("unifi.apiKey"));
        Assert.Null(prefs.GetString("unifi.apiKey")); // old copy cleared
    }
}
