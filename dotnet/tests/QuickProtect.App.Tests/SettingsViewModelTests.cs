using QuickProtect.App.ViewModels;
using QuickProtect.Core.Services;
using QuickProtect.Core.Tests;
using Xunit;
using static QuickProtect.App.Tests.ViewModelHarness;
using static QuickProtect.Core.Tests.FakeProtectConsole;
using Loc = QuickProtect.App.Localization.Loc;

namespace QuickProtect.App.Tests;

/// <summary>The Settings window's view model: write-through settings, sites, and the connection/PTZ tests.</summary>
public class SettingsViewModelTests
{
    private static SettingsViewModel NewSettings(ViewModelHarness h, AppSettings? settings = null)
        => new(h.Hub, settings ?? h.Settings, h.Trust, new UpdateChecker("1.0"));

    [Fact]
    public void Keep_panel_open_round_trips_through_the_stored_settings() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness();
        var vm = NewSettings(h);
        Assert.False(vm.KeepPanelOpen);

        vm.KeepPanelOpen = true;
        Assert.True(h.Settings.KeepPanelOpen);

        // The next launch reads it back.
        var reloaded = new AppSettings(h.Prefs, h.Secrets);
        Assert.True(reloaded.KeepPanelOpen);
        Assert.True(NewSettings(h, reloaded).KeepPanelOpen);

        vm.KeepPanelOpen = false;
        Assert.False(new AppSettings(h.Prefs, h.Secrets).KeepPanelOpen);
    });

    [Fact]
    public void The_keep_alive_picker_stores_seconds_and_gates_the_pause_decode_row() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness();
        var vm = NewSettings(h);
        var raised = new List<string?>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        // Default grace is 10 s, so the pause-decode switch applies.
        Assert.Equal("10 s", vm.KeepAliveOptions[vm.KeepAliveIndex]);
        Assert.True(vm.PauseDecodeRowVisible);

        vm.KeepAliveIndex = 0; // Off
        Assert.Equal(0, h.Settings.StreamKeepAliveSeconds);
        Assert.False(vm.PauseDecodeRowVisible);
        Assert.Contains(nameof(SettingsViewModel.PauseDecodeRowVisible), raised);

        vm.KeepAliveIndex = vm.KeepAliveOptions.Length - 1;
        Assert.Equal(60, h.Settings.StreamKeepAliveSeconds);
        Assert.True(vm.PauseDecodeRowVisible);

        Assert.True(vm.PauseDecodeWhileClosed);
        vm.PauseDecodeWhileClosed = false;
        var reloaded = new AppSettings(h.Prefs, h.Secrets);
        Assert.False(reloaded.PauseDecodeWhileClosed);
        Assert.Equal(60, reloaded.StreamKeepAliveSeconds);
        Assert.Equal(vm.KeepAliveOptions.Length - 1, NewSettings(h, reloaded).KeepAliveIndex);
    });

    [Fact]
    public void An_added_site_is_selected_and_edits_go_to_the_selected_site() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness();
        var vm = NewSettings(h);
        Assert.Single(vm.SiteRows);
        Assert.False(vm.HasMultipleSites);

        vm.AddSiteCommand.Execute(null);
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.Equal(2, vm.SiteRows.Count);
        Assert.True(vm.HasMultipleSites);
        Assert.Equal(1, vm.SelectedSiteIndex);
        Assert.Equal("", vm.IpAddress);
        Assert.Equal("", vm.ApiKey);
        Assert.Equal(2, h.Hub.Sites.Count);

        vm.SiteName = " Cabin ";
        vm.IpAddress = " 10.9.8.7 ";
        vm.ApiKey = "cabin-key\n";
        vm.Username = " ptz2 ";
        vm.Password = " pw2 ";
        var cabin = h.Settings.Sites[1];
        Assert.Equal("Cabin", cabin.Name);
        Assert.Equal("10.9.8.7", cabin.IpAddress);
        Assert.Equal("cabin-key", cabin.ApiKey);
        Assert.Equal("ptz2", cabin.Username);
        Assert.Equal(" pw2 ", cabin.Password); // passwords keep their spaces
        Assert.Equal("Cabin", vm.SiteRows[1].DisplayName);

        // Back to the first site: its values load, and neither site takes the other's.
        vm.SelectedSiteIndex = 0;
        Assert.Equal(h.Console.Address, vm.IpAddress);
        Assert.Equal("test-api-key", vm.ApiKey);
        Assert.Equal("", vm.Username);
        Assert.Equal("10.9.8.7", cabin.IpAddress);
        Assert.Equal("ptz2", cabin.Username);
        Assert.Equal(h.Console.Address, h.Site.IpAddress);
        Assert.Equal("", h.Site.Username);
    });

    [Fact]
    public void Removing_a_site_asks_first_and_the_last_site_stays() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness();
        var vm = NewSettings(h);
        vm.AddSiteCommand.Execute(null);
        var asked = 0;
        var answer = false;
        vm.ConfirmAsync = (_, _, _) => { asked++; return Task.FromResult(answer); };

        Pump(vm.RemoveSiteCommand.ExecuteAsync(null));
        Assert.Equal(1, asked);
        Assert.Equal(2, h.Settings.Sites.Count);

        answer = true;
        Pump(vm.RemoveSiteCommand.ExecuteAsync(null));
        // The selected (new) site went; the first one stays selected.
        Assert.Equal(new[] { ControllerSite.LegacyId }, h.Settings.Sites.Select(s => s.Id));
        Assert.Single(vm.SiteRows);
        Assert.Equal(0, vm.SelectedSiteIndex);
        Assert.False(vm.HasMultipleSites);
        Assert.Single(h.Hub.Sites);

        Pump(vm.RemoveSiteCommand.ExecuteAsync(null));
        Assert.Equal(2, asked); // never asked about the last site
        Assert.Single(h.Settings.Sites);
    });

    [Fact]
    public void Test_connection_stores_the_canonical_address_and_reports_the_cameras() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        var vm = NewSettings(h);
        vm.SelectedSectionIndex = 1; // Connection
        vm.IpAddress = $" https://{h.Console.Address}/protect/dashboard ";

        Pump(vm.TestConnectionCommand.ExecuteAsync(null));

        Assert.Equal(h.Console.Address, vm.IpAddress);
        Assert.Equal(h.Console.Address, h.Site.IpAddress);
        Assert.Equal(Loc.Get("Connected — %lld cameras found").Replace("%lld", "3"), vm.StatusMessage);
        Assert.True(vm.BadgeConnected);
        Assert.Equal(Loc.Get("Connected"), vm.BadgeText);
        Assert.True(vm.SiteRows[0].Connected);
    });

    [Fact]
    public void Test_connection_reports_a_rejected_key() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        h.Console.Override = r => r.Route == IntegrationCameras ? new FakeResponse(401, "{}") : null;
        var vm = NewSettings(h);
        vm.SelectedSectionIndex = 1;

        Pump(vm.TestConnectionCommand.ExecuteAsync(null));

        Assert.Equal(string.Format(Loc.Get("Error: {0}"), Loc.Get(ControllerErrors.ApiKeyRejected)), vm.StatusMessage);
        Assert.False(vm.BadgeConnected);
        Assert.Equal(Loc.Get("Disconnected"), vm.BadgeText);
    });

    [Fact]
    public void Test_connection_refuses_a_console_that_is_already_added() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness();
        var vm = NewSettings(h);
        vm.AddSiteCommand.Execute(null);
        vm.IpAddress = h.Console.Address;
        vm.ApiKey = "other-key";
        var listsBefore = h.Console.Controller.To(IntegrationCameras).Count;

        Pump(vm.TestConnectionCommand.ExecuteAsync(null));

        Assert.Equal(string.Format(Loc.Get("This console is already added as “{0}”."), h.Site.DisplayName),
                     vm.StatusMessage);
        Assert.Equal(listsBefore, h.Console.Controller.To(IntegrationCameras).Count);
    });

    [Fact]
    public void The_PTZ_test_signs_in_and_the_badge_follows_the_login() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(username: "ptz", password: "secret", fetch: false);
        var vm = NewSettings(h);
        vm.SelectedSectionIndex = 2; // PTZ
        Assert.Equal(Loc.Get("Not verified"), vm.BadgeText);
        Assert.False(vm.BadgeConnected);

        Pump(vm.TestPtzCommand.ExecuteAsync(null));
        Assert.Equal(Loc.Get("Signed in · PTZ control ready"), vm.PtzStatusMessage);
        Assert.True(vm.BadgeConnected);
        Assert.Equal(Loc.Get("Connected"), vm.BadgeText);

        h.Console.Override = r => r.Route == Login ? new FakeResponse(401, "{}") : null;
        vm.Password = "wrong";
        Pump(vm.TestPtzCommand.ExecuteAsync(null));
        Assert.Equal(Loc.Get("Login failed — check the username and password"), vm.PtzStatusMessage);
        Assert.False(vm.BadgeConnected);
        Assert.Equal(Loc.Get("Not verified"), vm.BadgeText);
        // The attempt used what was just typed.
        Assert.Contains("\"wrong\"", h.Console.Controller.To(Login)[^1].Body);

        vm.Username = "";
        Assert.Equal(Loc.Get("Not configured"), vm.BadgeText);
    });
}

/// <summary>Settings' "Cameras &amp; Layout" tab.</summary>
public class LayoutViewModelTests
{
    private static readonly string ThreeCameras = CameraList(
        ("cam1", "Driveway", "CONNECTED"), ("cam2", "Yard", "CONNECTED"), ("cam3", "Front Door", "CONNECTED"));

    private static string[] Ids(LayoutViewModel vm) => vm.Rows.Select(r => r.Camera.Id).ToArray();
    private static CameraRowViewModel Row(LayoutViewModel vm, string id) => vm.Rows.Single(r => r.Camera.Id == id);

    [Fact]
    public void Rows_list_every_camera_in_profile_order_and_write_through() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        h.Settings.SetHidden(true, "cam2");
        h.Settings.SetCameraOrder(new[] { "cam3", "cam2", "cam1" });
        var vm = new LayoutViewModel(h.Hub, h.Settings);

        // Hidden cameras are listed too, so they can be shown again.
        Assert.Equal(new[] { "cam3", "cam2", "cam1" }, Ids(vm));
        Assert.False(Row(vm, "cam2").IsVisible);
        Assert.True(Row(vm, "cam1").IsVisible);

        Row(vm, "cam2").IsVisible = true;
        Assert.False(h.Settings.IsHidden("cam2"));
        Row(vm, "cam1").IsVisible = false;
        Assert.True(h.Settings.IsHidden("cam1"));

        Row(vm, "cam3").SizeIndex = 2;
        Assert.Equal(AppSettings.CameraSize.Large, h.Settings.SizeFor("cam3"));
        Row(vm, "cam3").SizeIndex = 0;
        Assert.Equal(AppSettings.CameraSize.Small, h.Settings.SizeFor("cam3"));

        Row(vm, "cam1").MoveUpCommand.Execute(null);
        Assert.Equal(new[] { "cam3", "cam1", "cam2" }, Ids(vm));
        Assert.Equal(new[] { "cam3", "cam1", "cam2" }, h.Settings.CameraOrder());
        Row(vm, "cam3").MoveUpCommand.Execute(null);   // already first
        Row(vm, "cam2").MoveDownCommand.Execute(null); // already last
        Assert.Equal(new[] { "cam3", "cam1", "cam2" }, h.Settings.CameraOrder());

        // A camera the console adds later gets a row.
        h.Console.IntegrationBody = CameraList(
            ("cam1", "Driveway", "CONNECTED"), ("cam2", "Yard", "CONNECTED"),
            ("cam3", "Front Door", "CONNECTED"), ("cam4", "Garage", "CONNECTED"));
        h.Refetch();
        Assert.Equal(new[] { "cam3", "cam1", "cam2", "cam4" }, Ids(vm));
    });

    [Fact]
    public void Profiles_can_be_created_renamed_switched_and_deleted() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        var vm = new LayoutViewModel(h.Hub, h.Settings);

        vm.NewProfileName = "   ";
        vm.CreateProfileCommand.Execute(null);
        Assert.Single(h.Settings.Profiles());

        vm.NewProfileName = " Night ";
        vm.CreateProfileCommand.Execute(null);
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.Equal("", vm.NewProfileName);
        Assert.Equal(new[] { "Default", "Night" }, vm.ProfileNames);
        Assert.Equal(1, vm.SelectedProfileIndex);
        Assert.Equal("Night", h.Settings.ActiveProfile.Name);

        Row(vm, "cam1").IsVisible = false; // in Night only

        vm.NewProfileName = "Late night";
        vm.RenameProfileCommand.Execute(null);
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.Equal(new[] { "Default", "Late night" }, vm.ProfileNames);

        vm.SelectedProfileIndex = 0;
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.Equal(AppSettings.DefaultProfileId, h.Settings.ActiveProfileId);
        Assert.True(Row(vm, "cam1").IsVisible);

        vm.SelectedProfileIndex = 1;
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.False(Row(vm, "cam1").IsVisible);

        vm.DeleteProfileCommand.Execute(null);
        PumpFor(TimeSpan.FromMilliseconds(20));
        Assert.Equal(new[] { "Default" }, vm.ProfileNames);
        Assert.Equal(0, vm.SelectedProfileIndex);
        Assert.Equal(AppSettings.DefaultProfileId, h.Settings.ActiveProfileId);
        Assert.True(Row(vm, "cam1").IsVisible);

        vm.DeleteProfileCommand.Execute(null); // the last profile stays
        Assert.Single(h.Settings.Profiles());
    });
}

/// <summary>The first-run wizard.</summary>
public class OnboardingViewModelTests
{
    private sealed class RecordingLaunchAtLogin : ILaunchAtLogin
    {
        public bool IsEnabled { get; private set; }
        public void SetEnabled(bool enabled) => IsEnabled = enabled;
    }

    [Fact]
    public void Continue_saves_the_connection_and_finish_completes_onboarding() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        var launch = new RecordingLaunchAtLogin();
        h.Settings.LaunchManager = launch;
        var vm = new OnboardingViewModel(h.Hub, h.Settings);
        var finished = 0;
        vm.Finished += (_, _) => finished++;
        Assert.True(vm.IsStep1);
        Assert.False(vm.CanGoBack);

        vm.IpAddress = " 10.1.2.3 ";
        vm.ApiKey = " key\n";
        vm.Username = " ptz ";
        vm.Password = " pw ";
        vm.BackCommand.Execute(null);
        Assert.True(vm.IsStep1);

        vm.ContinueCommand.Execute(null);
        Assert.True(vm.IsStep2);
        Assert.Equal("10.1.2.3", h.Site.IpAddress);
        Assert.Equal("key", h.Site.ApiKey);
        Assert.Equal("ptz", h.Site.Username);
        Assert.Equal(" pw ", h.Site.Password);

        vm.ContinueCommand.Execute(null);
        Assert.True(vm.IsStep3);
        Assert.Equal(Loc.Get("Finish"), vm.ContinueLabel);
        vm.BackCommand.Execute(null);
        Assert.True(vm.IsStep2);
        Assert.Equal(Loc.Get("Continue"), vm.ContinueLabel);
        vm.ContinueCommand.Execute(null);
        Assert.Equal(0, finished);
        Assert.False(h.Settings.HasCompletedOnboarding);

        vm.LaunchAtLogin = true;
        vm.ContinueCommand.Execute(null);

        Assert.Equal(1, finished);
        Assert.True(launch.IsEnabled);
        var reloaded = new AppSettings(h.Prefs, h.Secrets);
        Assert.True(reloaded.HasCompletedOnboarding);
        Assert.True(reloaded.HasShownAutoStartPrompt);
    });

    [Fact]
    public void Skip_finishes_with_what_was_entered() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        var vm = new OnboardingViewModel(h.Hub, h.Settings);
        var finished = false;
        vm.Finished += (_, _) => finished = true;

        vm.IpAddress = "10.4.5.6";
        vm.SkipCommand.Execute(null);

        Assert.True(finished);
        Assert.True(h.Settings.HasCompletedOnboarding);
        Assert.Equal("10.4.5.6", h.Site.IpAddress);
    });

    [Fact]
    public void Test_connection_counts_the_consoles_cameras() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        var vm = new OnboardingViewModel(h.Hub, h.Settings);
        Assert.Equal(h.Console.Address, vm.IpAddress); // prefilled from the site

        Pump(vm.TestConnectionCommand.ExecuteAsync(null));

        Assert.Equal(3, vm.CameraCount);
        Assert.Equal(Loc.Get("Connected — %lld cameras found").Replace("%lld", "3"), vm.StatusMessage);
        Assert.Equal(3, h.Hub.Cameras.Count);
    });

    [Fact]
    public void Test_connection_reports_an_unreachable_console() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(fetch: false);
        h.Console.Override = r => r.Route == IntegrationCameras ? new FakeResponse(503, "{}") : null;
        var vm = new OnboardingViewModel(h.Hub, h.Settings);

        Pump(vm.TestConnectionCommand.ExecuteAsync(null));

        Assert.Equal(0, vm.CameraCount);
        Assert.Equal(string.Format(Loc.Get("Error: {0}"), Loc.Get(ControllerErrors.ServerError)), vm.StatusMessage);
    });
}
