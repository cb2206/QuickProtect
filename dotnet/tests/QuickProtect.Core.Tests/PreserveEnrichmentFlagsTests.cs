using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Tests for the enrichment-flag carry-over on camera-list refresh: Integration
/// API responses have no featureFlags, so a fetch inside the PTZ-enrichment
/// throttle window must not lose the classic-API IsPtz/CanZoom flags (the
/// regression that hid PTZ overlays after a panel reopen).
/// </summary>
public class PreserveEnrichmentFlagsTests
{
    private static Camera Cam(string id, bool ptz = false, bool zoom = false)
        => new() { Id = id, Name = id, IsPtz = ptz, CanZoom = zoom };

    [Fact]
    public void Carries_flags_onto_fresh_list_by_id()
    {
        var previous = new[] { Cam("a", ptz: true, zoom: true), Cam("b") };
        var fresh = new[] { Cam("a"), Cam("b") };
        var result = ProtectService.PreserveEnrichmentFlags(previous, fresh);
        Assert.True(result[0].IsPtz);
        Assert.True(result[0].CanZoom);
        Assert.False(result[1].IsPtz);
        Assert.False(result[1].CanZoom);
    }

    [Fact]
    public void Never_clears_flags_already_on_the_fresh_list()
    {
        var previous = new[] { Cam("a") };
        var fresh = new[] { Cam("a", ptz: true, zoom: true) };
        var result = ProtectService.PreserveEnrichmentFlags(previous, fresh);
        Assert.True(result[0].IsPtz);
        Assert.True(result[0].CanZoom);
    }

    [Fact]
    public void Ignores_cameras_that_left_the_list()
    {
        var previous = new[] { Cam("gone", ptz: true) };
        var fresh = new[] { Cam("new") };
        var result = ProtectService.PreserveEnrichmentFlags(previous, fresh);
        Assert.False(result[0].IsPtz);
    }

    [Fact]
    public void Empty_previous_list_returns_fresh_unchanged()
    {
        var fresh = new[] { Cam("a", ptz: true) };
        var result = ProtectService.PreserveEnrichmentFlags(Array.Empty<Camera>(), fresh);
        Assert.Same(fresh, result);
        Assert.True(result[0].IsPtz);
    }

    [Fact]
    public void Zoom_and_ptz_carry_independently()
    {
        var previous = new[] { Cam("a", ptz: true), Cam("b", zoom: true) };
        var fresh = new[] { Cam("a"), Cam("b") };
        var result = ProtectService.PreserveEnrichmentFlags(previous, fresh);
        Assert.True(result[0].IsPtz);
        Assert.False(result[0].CanZoom);
        Assert.False(result[1].IsPtz);
        Assert.True(result[1].CanZoom);
    }
}
