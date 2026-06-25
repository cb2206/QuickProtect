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
