using QuickProtect.App.ViewModels;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using QuickProtect.Core.Tests;
using Xunit;
using static QuickProtect.App.Tests.ViewModelHarness;
using static QuickProtect.Core.Tests.FakeProtectConsole;

namespace QuickProtect.App.Tests;

/// <summary>
/// The panel's view model against a real hub and a scripted console: the tile
/// collection follows the camera list and the active profile, search filters
/// it, focus mode comes and goes, and the header readouts update.
/// </summary>
public class MainViewModelTests
{
    private static readonly string ThreeCameras = CameraList(
        ("cam1", "Driveway", "CONNECTED"), ("cam2", "Yard", "DISCONNECTED"), ("cam3", "Front Door", "CONNECTED"));

    private static string[] Ids(MainViewModel vm) => vm.Tiles.Select(t => t.Camera.Id).ToArray();
    private static CameraTileViewModel Tile(MainViewModel vm, string id) => vm.Tiles.Single(t => t.Camera.Id == id);

    [Fact]
    public void Tiles_follow_the_profile_order_and_visibility() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        h.Settings.SetCameraOrder(new[] { "cam3", "cam1", "cam2" });
        h.Settings.SetHidden(true, "cam2");
        using var vm = new MainViewModel(h.Hub, h.Settings);

        Assert.Equal(new[] { "cam3", "cam1" }, Ids(vm));
        Assert.True(vm.ShowGrid);
        Assert.False(vm.ShowEmptyState);
        Assert.Equal(2, vm.StreamCount);

        vm.UnhideCamera("cam2");
        Assert.Equal(new[] { "cam3", "cam1", "cam2" }, Ids(vm));
        Assert.Equal(2, vm.StreamCount); // cam2 is offline: no stream

        vm.HideCamera(Tile(vm, "cam3"));
        Assert.Equal(new[] { "cam1", "cam2" }, Ids(vm));
        Assert.Equal(1, vm.StreamCount);
        Assert.Equal(new[] { "cam3" }, vm.HiddenCameras().Select(c => c.Id));
    });

    [Fact]
    public void A_new_camera_list_updates_tiles_in_place() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);
        var driveway = Tile(vm, "cam1");
        var door = Tile(vm, "cam3");

        h.Console.IntegrationBody = CameraList(
            ("cam4", "Garage", "CONNECTED"), ("cam1", "Driveway (north)", "CONNECTED"), ("cam2", "Yard", "CONNECTED"));
        h.Refetch();

        Assert.Equal(new[] { "cam4", "cam1", "cam2" }, Ids(vm));
        // A camera that stays keeps its tile (and its stream), refreshed in place.
        Assert.Same(driveway, Tile(vm, "cam1"));
        Assert.Equal("Driveway (north)", driveway.Name);
        Assert.True(Tile(vm, "cam2").IsOnline);
        Assert.Equal(3, vm.StreamCount);
        // A camera that left is dropped and stopped.
        Assert.DoesNotContain(door, vm.Tiles);
        Assert.Null(door.Client);
        Assert.False(door.IsPlaying);
    });

    [Fact]
    public void Search_filters_by_name_including_tiles_added_later() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);

        vm.SearchQuery = "  door ";
        Assert.Equal(new[] { "cam3" }, vm.Tiles.Where(t => t.MatchesSearch).Select(t => t.Camera.Id));
        vm.SearchQuery = "DRIVE";
        Assert.Equal(new[] { "cam1" }, vm.Tiles.Where(t => t.MatchesSearch).Select(t => t.Camera.Id));

        vm.SearchQuery = "door";
        h.Console.IntegrationBody = CameraList(
            ("cam1", "Driveway", "CONNECTED"), ("cam3", "Front Door", "CONNECTED"),
            ("cam4", "Back door", "CONNECTED"), ("cam5", "Garage", "CONNECTED"));
        h.Refetch();
        Assert.Equal(new[] { "cam3", "cam4" }, vm.Tiles.Where(t => t.MatchesSearch).Select(t => t.Camera.Id));

        vm.SearchQuery = "";
        Assert.All(vm.Tiles, t => Assert.True(t.MatchesSearch));
    });

    [Fact]
    public void A_failing_console_shows_the_error_banner_until_it_recovers() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras, fetch: false);
        h.Console.Override = r => r.Route == IntegrationCameras ? new FakeResponse(401, """{"error":"Unauthorized"}""") : null;
        h.Refetch();
        using var vm = new MainViewModel(h.Hub, h.Settings);

        Assert.Equal(Localization.Loc.Get(ControllerErrors.ApiKeyRejected), vm.ErrorMessage);
        Assert.True(vm.ShowErrorBanner);
        Assert.True(vm.ShowEmptyState);
        Assert.Empty(vm.Tiles);

        h.Console.Override = null;
        h.Refetch();

        Assert.Null(vm.ErrorMessage);
        Assert.False(vm.ShowErrorBanner);
        Assert.Equal(new[] { "cam1", "cam2", "cam3" }, Ids(vm));
    });

    [Fact]
    public void Switching_profiles_rebuilds_the_tiles_and_the_switcher_follows_settings() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);
        Assert.Equal(new[] { "Default" }, vm.ProfileNames);

        // Created from the Settings window: a copy of the current layout, now active.
        var night = h.Settings.CreateProfile("Night");
        PumpUntil(() => vm.ProfileNames.Count == 2);
        Assert.Equal(new[] { "Default", "Night" }, vm.ProfileNames);
        Assert.Equal(1, vm.SelectedProfileIndex);

        vm.HideCamera(Tile(vm, "cam1"));
        Assert.Equal(new[] { "cam2", "cam3" }, Ids(vm));

        // The panel's own switcher.
        vm.SelectedProfileIndex = 0;
        PumpFor(TimeSpan.FromMilliseconds(50));
        Assert.Equal(AppSettings.DefaultProfileId, h.Settings.ActiveProfileId);
        Assert.Equal(new[] { "cam1", "cam2", "cam3" }, Ids(vm));

        // Switched elsewhere (Settings' layout tab).
        h.Settings.SwitchProfile(night);
        PumpUntil(() => vm.SelectedProfileIndex == 1);
        Assert.Equal(new[] { "cam2", "cam3" }, Ids(vm));
    });

    [Fact]
    public void Focus_enters_once_and_exit_returns_to_the_grid() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);
        var cameras = h.Hub.Cameras.ToDictionary(c => c.Id);

        vm.Focus(cameras["cam1"]);
        Assert.True(vm.IsFocusMode);
        Assert.False(vm.IsGridMode);
        var focus = vm.FocusTile;
        Assert.NotNull(focus);
        Assert.Equal("cam1", focus.Camera.Id);
        Assert.True(focus.IsFocused);
        // The focus view has its own tile; the grid keeps its tiles.
        Assert.DoesNotContain(focus, vm.Tiles);
        Assert.Equal(3, vm.Tiles.Count);

        vm.Focus(cameras["cam3"]); // already focused: ignored
        Assert.Same(focus, vm.FocusTile);

        vm.ExitFocus();
        Assert.False(vm.IsFocusMode);
        Assert.True(vm.IsGridMode);
        Assert.Null(vm.FocusTile);
        Assert.Null(focus.Client);
        vm.ExitFocus(); // no-op
    });

    [Fact]
    public void The_focus_tile_follows_the_camera_list_and_ends_when_its_camera_leaves() => UiThread.Run(() =>
    {
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);

        vm.Focus(h.Hub.Cameras.Single(c => c.Id == "cam3"));
        h.Console.IntegrationBody = CameraList(("cam1", "Driveway", "CONNECTED"), ("cam3", "Porch", "CONNECTED"));
        h.Refetch();
        Assert.Equal("Porch", vm.FocusTile?.Name);

        h.Console.IntegrationBody = CameraList(("cam1", "Driveway", "CONNECTED"));
        h.Refetch();
        Assert.False(vm.IsFocusMode);
        Assert.Equal(new[] { "cam1" }, Ids(vm));
    });

    [Fact]
    public void Leaving_focus_stops_a_moving_PTZ_camera() => UiThread.Run(() =>
    {
        // The default script flags cam1 as PTZ once the classic login succeeds.
        using var h = new ViewModelHarness(username: "ptz", password: "secret");
        using var vm = new MainViewModel(h.Hub, h.Settings);
        vm.Focus(h.Hub.Cameras.Single(c => c.Id == "cam1"));
        var focus = vm.FocusTile;
        Assert.NotNull(focus);
        Assert.True(focus.IsPtz);

        focus.PtzPress(PtzDirection.Right);
        Assert.True(focus.PtzRightActive);
        vm.ExitFocus();

        var moveTask = h.Console.Controller.WaitFor(Move("cam1"), count: 2);
        Pump(moveTask);
        var moves = moveTask.Result;
        Assert.Equal((1000, 0, 0), Velocities(moves[0]));
        Assert.Equal((0, 0, 0), Velocities(moves[1]));
        Assert.False(focus.PtzRightActive);
    });

    [Fact]
    public void The_bitrate_readout_starts_empty_and_a_restart_drops_the_hidden_interval() => UiThread.Run(() =>
    {
        // The readout's timer needs a platform dispatcher, which these tests
        // don't run; they take its samples by hand.
        using var h = new ViewModelHarness(ThreeCameras);
        using var vm = new MainViewModel(h.Hub, h.Settings);

        vm.StartBitrateUpdates();
        Assert.Equal("", vm.BitrateLabel); // one sample is no rate yet
        StreamTraffic.Add(1_000_000);
        Thread.Sleep(50);
        vm.SampleBitrate();
        Assert.StartsWith("· ", vm.BitrateLabel);
        Assert.EndsWith(" Mbps", vm.BitrateLabel);

        // Hidden, then shown again: no stale reading, and the traffic while
        // hidden isn't billed to the first second back (no stream feeds the
        // counter in these tests).
        vm.StopBitrateUpdates();
        StreamTraffic.Add(50_000_000);
        vm.StartBitrateUpdates();
        Assert.Equal("", vm.BitrateLabel);
        Thread.Sleep(50);
        vm.SampleBitrate();
        Assert.Equal("· 0 kbps", vm.BitrateLabel);
    });
}
