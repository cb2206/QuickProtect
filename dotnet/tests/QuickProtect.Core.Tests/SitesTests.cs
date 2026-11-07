using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;
using FakeController = QuickProtect.Core.Tests.ConnectionChangeTests.FakeController;

namespace QuickProtect.Core.Tests;

/// <summary>
/// Multi-site support: the site list and its migration from the single-controller
/// settings, per-site secrets, profile seeding for a new site, and
/// <see cref="ProtectHub"/> merging two (fake) consoles.
/// </summary>
public class SitesTests
{
    private static string CameraList(params string[] ids)
        => "{\"data\":[" + string.Join(",", ids.Select(id => $"{{\"id\":\"{id}\",\"name\":\"{id}\",\"state\":\"CONNECTED\"}}")) + "]}";

    // MARK: - Settings

    [Fact]
    public void Single_controller_configuration_migrates_into_the_first_site()
    {
        var prefs = new InMemoryPreferences();
        var secrets = new InMemorySecretStore();
        prefs.SetString("unifi.ipAddress", "10.0.1.1");
        secrets.Set("unifi.apiKey", "key");
        secrets.Set("unifi.username", "admin");

        var settings = new AppSettings(prefs, secrets);

        var site = Assert.Single(settings.Sites);
        Assert.Equal(ControllerSite.LegacyId, site.Id);
        Assert.Equal("10.0.1.1", site.IpAddress);
        Assert.Equal("key", site.ApiKey);
        Assert.Equal("admin", site.Username);
        Assert.True(site.IsConfigured);
        Assert.False(settings.HasMultipleSites);
        Assert.Contains(ControllerSite.LegacyId, settings.SeededSiteIds());
    }

    [Fact]
    public void First_site_keeps_the_legacy_storage_so_a_downgrade_still_works()
    {
        var prefs = new InMemoryPreferences();
        var secrets = new InMemorySecretStore();
        var site = new AppSettings(prefs, secrets).Sites[0];
        site.IpAddress = "192.168.1.10:8443";
        site.ApiKey = "key-1";
        site.Password = "pw";

        Assert.Equal("192.168.1.10:8443", prefs.GetString("unifi.ipAddress"));
        Assert.Equal("key-1", secrets.Get("unifi.apiKey"));
        Assert.Equal("pw", secrets.Get("unifi.password"));
        Assert.Null(prefs.GetString("unifi.apiKey"));

        var reloaded = new AppSettings(prefs, secrets).Sites[0];
        Assert.Equal("192.168.1.10:8443", reloaded.IpAddress);
        Assert.Equal("key-1", reloaded.ApiKey);
    }

    [Fact]
    public void Added_site_stores_its_secrets_under_its_own_accounts()
    {
        var prefs = new InMemoryPreferences();
        var secrets = new InMemorySecretStore();
        var settings = new AppSettings(prefs, secrets);
        settings.Sites[0].ApiKey = "inca-key";
        var added = settings.AddSite("BC285");
        added.IpAddress = "10.1.1.1";
        added.ApiKey = "bc-key";

        Assert.True(settings.HasMultipleSites);
        Assert.Equal("bc-key", secrets.Get($"unifi.apiKey.{added.Id}"));
        Assert.Equal("inca-key", secrets.Get("unifi.apiKey"));
        Assert.DoesNotContain(added.Id, settings.SeededSiteIds());

        var reloaded = new AppSettings(prefs, secrets);
        Assert.Equal(new[] { ControllerSite.LegacyId, added.Id }, reloaded.Sites.Select(s => s.Id));
        var again = reloaded.Site(added.Id)!;
        Assert.Equal("BC285", again.DisplayName);
        Assert.Equal("10.1.1.1", again.IpAddress);
        Assert.Equal("bc-key", again.ApiKey);
    }

    [Fact]
    public void Removing_a_site_deletes_its_secrets_but_never_the_last_site()
    {
        var secrets = new InMemorySecretStore();
        var settings = new AppSettings(new InMemoryPreferences(), secrets);
        var added = settings.AddSite();
        added.ApiKey = "bc-key";
        var changes = 0;
        settings.SitesChanged += (_, _) => changes++;

        settings.RemoveSite(added.Id);
        Assert.Equal(new[] { ControllerSite.LegacyId }, settings.Sites.Select(s => s.Id));
        Assert.Null(secrets.Get($"unifi.apiKey.{added.Id}"));
        Assert.Equal(1, changes);

        settings.RemoveSite(ControllerSite.LegacyId);
        Assert.Single(settings.Sites);
    }

    [Fact]
    public void Connection_change_fires_only_for_address_or_key()
    {
        var site = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore()).Sites[0];
        var changes = 0;
        site.ConnectionChanged += (_, _) => changes++;
        site.IpAddress = "10.0.0.1";
        site.IpAddress = "10.0.0.1";   // re-applied on focus loss: not a change
        site.ApiKey = "k";
        site.Name = "Inca";
        site.Username = "admin";
        Assert.Equal(2, changes);
        Assert.Equal("Inca", site.DisplayName);
    }

    [Fact]
    public void New_site_cameras_are_hidden_outside_the_active_profile()
    {
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore());
        var other = settings.CreateProfile("Driveway only"); // switches to it
        settings.SwitchProfile(AppSettings.DefaultProfileId);
        var added = settings.AddSite("BC285");

        Assert.True(settings.SeedSiteCamerasIfNeeded(added.Id, new[] { "bc1", "bc2" }));
        Assert.False(settings.IsHidden("bc1"));
        settings.SwitchProfile(other);
        Assert.True(settings.IsHidden("bc1"));
        Assert.True(settings.IsHidden("bc2"));

        Assert.False(settings.SeedSiteCamerasIfNeeded(added.Id, new[] { "bc3" }));
        Assert.False(settings.IsHidden("bc3"));
        Assert.False(settings.SeedSiteCamerasIfNeeded(ControllerSite.LegacyId, new[] { "inca1" }));
        Assert.False(settings.SeedSiteCamerasIfNeeded(added.Id, Array.Empty<string>()));
    }

    // MARK: - Hub

    private static (ProtectHub Hub, AppSettings Settings, ControllerSite Inca, ControllerSite Bc) NewHub(
        string incaAddress, string bcAddress)
    {
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore());
        var inca = settings.Sites[0];
        inca.Name = "Inca";
        inca.IpAddress = incaAddress;
        inca.ApiKey = "inca-key";
        var bc = settings.AddSite("BC285");
        bc.IpAddress = bcAddress;
        bc.ApiKey = "bc-key";
        var trust = new CertificateTrust(new InMemoryPreferences());
        return (new ProtectHub(settings, site => new ProtectService(site, trust)), settings, inca, bc);
    }

    [Fact]
    public async Task Hub_merges_both_sites_and_routes_by_camera()
    {
        await using var incaConsole = new FakeController(CameraList("i1", "i2"));
        await using var bcConsole = new FakeController(CameraList("b1"));
        var (hub, _, inca, bc) = NewHub(incaConsole.Address, bcConsole.Address);
        using var _ = hub;

        await hub.FetchCamerasAsync(forced: true);

        Assert.Equal(new[] { "i1", "i2", "b1" }, hub.Cameras.Select(c => c.Id));
        Assert.Equal(new[] { inca.Id, inca.Id, bc.Id }, hub.Cameras.Select(c => c.SiteId));
        Assert.Empty(hub.SiteIssues);
        Assert.Equal(bc.Id, hub.ServiceForCameraId("b1")?.SiteId);
        Assert.Equal("BC285", hub.SiteBadge(hub.Cameras[2]));
        Assert.Equal(bcConsole.Address, hub.ControllerAddressFor(hub.Cameras[2])?.Authority);
        Assert.Contains(incaConsole.Heads, h => h.Contains("X-API-Key: inca-key"));
        Assert.Contains(bcConsole.Heads, h => h.Contains("X-API-Key: bc-key"));
        Assert.DoesNotContain(bcConsole.Heads, h => h.Contains("inca-key"));
    }

    [Fact]
    public async Task First_fetch_of_an_added_site_seeds_the_profiles()
    {
        await using var incaConsole = new FakeController(CameraList("i1"));
        await using var bcConsole = new FakeController(CameraList("b1"));
        var (hub, settings, _, _) = NewHub(incaConsole.Address, bcConsole.Address);
        using var _ = hub;
        var other = settings.CreateProfile("Inca only");
        settings.SwitchProfile(AppSettings.DefaultProfileId);

        await hub.FetchCamerasAsync(forced: true);

        Assert.False(settings.IsHidden("b1"));
        settings.SwitchProfile(other);
        Assert.True(settings.IsHidden("b1"));
        Assert.False(settings.IsHidden("i1"));
    }

    [Fact]
    public async Task A_failing_site_is_an_issue_while_the_other_keeps_its_cameras()
    {
        await using var incaConsole = new FakeController(CameraList("i1"));
        await using var bcConsole = new FakeController("""{"error":"Unauthorized"}""", "401 Unauthorized");
        var (hub, _, _, bc) = NewHub(incaConsole.Address, bcConsole.Address);
        using var _ = hub;

        await hub.FetchCamerasAsync(forced: true);

        Assert.Equal(new[] { "i1" }, hub.Cameras.Select(c => c.Id));
        var issue = Assert.Single(hub.SiteIssues);
        Assert.Equal(bc.Id, issue.SiteId);
        Assert.Equal("BC285", issue.SiteName);
        Assert.Equal(ControllerErrors.ApiKeyRejected, issue.Message);
        Assert.False(issue.IsCertificateChange);
        Assert.Null(hub.BlockingCertificateChange);
    }

    [Fact]
    public async Task Removing_a_site_drops_its_cameras_and_announces_it()
    {
        await using var incaConsole = new FakeController(CameraList("i1"));
        await using var bcConsole = new FakeController(CameraList("b1"));
        var (hub, settings, _, bc) = NewHub(incaConsole.Address, bcConsole.Address);
        using var _ = hub;
        await hub.FetchCamerasAsync(forced: true);
        var removed = new List<string>();
        hub.SiteRemoved += (_, id) => removed.Add(id);

        settings.RemoveSite(bc.Id);

        Assert.Equal(new[] { bc.Id }, removed);
        Assert.Null(hub.ServiceForSite(bc.Id));
        Assert.Equal(new[] { "i1" }, hub.Cameras.Select(c => c.Id));
    }

    [Fact]
    public void Connection_changes_are_announced_per_site()
    {
        var (hub, _, _, bc) = NewHub("10.0.0.1", "10.0.0.2");
        using var _ = hub;
        var changed = new List<string>();
        hub.ConnectionChanged += (_, id) => changed.Add(id);
        bc.ApiKey = "rotated";
        bc.Name = "BC 285";
        Assert.Equal(new[] { bc.Id }, changed);
    }

    [Fact]
    public void Tunnel_pins_each_stream_under_its_own_site()
    {
        var (hub, _, _, _) = NewHub("10.0.1.1", "protect.bc285.lan:8443");
        using var _ = hub;
        Assert.Equal("10.0.1.1", hub.PinKeyFor("10.0.1.1"));
        Assert.Equal("protect.bc285.lan", hub.PinKeyFor("PROTECT.bc285.lan"));
        Assert.Equal("192.0.2.9", hub.PinKeyFor("192.0.2.9"));
    }

    [Fact]
    public void Single_site_has_no_badge()
    {
        var settings = new AppSettings(new InMemoryPreferences(), new InMemorySecretStore());
        using var hub = new ProtectHub(settings, site => new ProtectService(site, new CertificateTrust(new InMemoryPreferences())));
        Assert.Null(hub.SiteBadge(new Camera { Id = "x", Name = "x" }));
    }
}
