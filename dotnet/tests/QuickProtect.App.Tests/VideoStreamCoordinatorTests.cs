using System.Collections.Concurrent;
using QuickProtect.App.Video;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Drives <see cref="VideoStreamCoordinator"/> against a scripted
/// <see cref="IStreamAllocator"/>: which allocations it asks the controller
/// for, in what order, and when it releases them. The real
/// <see cref="VideoStreamClient"/> is used but never decodes anything — the
/// FFmpeg engine is not initialised, so its session thread fails fast and
/// backs off, which is exactly what an unreachable camera looks like.
/// </summary>
public class VideoStreamCoordinatorTests
{
    static VideoStreamCoordinatorTests()
    {
        // No session ever paints here, so a handover would otherwise wait out
        // the full switch grace before the old allocation is released.
        VideoStreamClient.SwitchGrace = TimeSpan.FromMilliseconds(300);
    }

    private static Camera Cam(string id) => new() { Id = id, Name = id };

    /// <summary>Scripted allocator: records calls, answers per quality, can hold a request.</summary>
    private sealed class FakeAllocator : IStreamAllocator
    {
        public readonly ConcurrentQueue<string> Calls = new();
        /// <summary>Quality requested → quality granted (null entry = allocation fails).</summary>
        public readonly ConcurrentDictionary<string, string?> Grants = new();
        /// <summary>When set, every Create call waits on it before answering.</summary>
        public TaskCompletionSource? Gate;

        public async Task<(string url, string quality)?> CreateRtspStreamUrlAsync(Camera camera, string quality)
            => await Create("create", camera, quality);

        public async Task<(string url, string quality)?> CreatePinnedStreamUrlAsync(Camera camera, string quality)
            => await Create("create-pinned", camera, quality);

        public void ReleaseStream(string cameraId, string quality) => Calls.Enqueue($"release {cameraId} {quality}");
        public void ReleasePinnedStream(string cameraId, string quality) => Calls.Enqueue($"release-pinned {cameraId} {quality}");

        private async Task<(string url, string quality)?> Create(string kind, Camera camera, string quality)
        {
            Calls.Enqueue($"{kind} {camera.Id} {quality}");
            var gate = Gate;
            if (gate != null) await gate.Task;
            var granted = Grants.TryGetValue(quality, out var g) ? g : quality;
            if (granted == null) return null;
            return ($"rtsps://controller:7441/{camera.Id}-{granted}", granted);
        }

        public string[] Snapshot() => Calls.ToArray();

        public async Task<bool> WaitFor(Func<string[], bool> condition, int timeoutMs = 5000)
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < deadline)
            {
                if (condition(Snapshot())) return true;
                await Task.Delay(20);
            }
            return condition(Snapshot());
        }
    }

    [Fact]
    public async Task First_consumer_allocates_at_its_desired_quality()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        using var handle = coord.Acquire(Cam("a"), "medium");

        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        Assert.Equal(new[] { "create a medium" }, svc.Snapshot());
    }

    [Fact]
    public async Task Second_consumer_at_higher_quality_upgrades_immediately_and_releases_old_after_handover()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        using var grid = coord.Acquire(Cam("a"), "medium");
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        using var focus = coord.Acquire(Cam("a"), "high");

        Assert.True(await svc.WaitFor(c => c.Contains("create a high")));
        // The new allocation exists before the old one goes away, and the old one
        // is only released once the previous session has ended (here: after the
        // switch grace, since the new session never paints).
        await Task.Delay(100);
        Assert.DoesNotContain("release a medium", svc.Snapshot());
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));
        var calls = svc.Snapshot();
        Assert.True(Array.IndexOf(calls, "create a high") < Array.IndexOf(calls, "release a medium"));
        Assert.Same(grid.Client, focus.Client);
    }

    [Fact]
    public async Task Downgrade_waits_for_the_settle_window()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        using var grid = coord.Acquire(Cam("a"), "medium");
        var focus = coord.Acquire(Cam("a"), "high");
        Assert.True(await svc.WaitFor(c => c.Contains("create a high")));
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));

        focus.Dispose();
        await Task.Delay(200);
        Assert.DoesNotContain("create a medium", svc.Snapshot().Skip(1)); // nothing yet: still settling
        Assert.True(await svc.WaitFor(c => c.Count(x => x == "create a medium") == 2, 3000));
        Assert.True(await svc.WaitFor(c => c.Contains("release a high")));
    }

    [Fact]
    public async Task Last_consumer_release_frees_the_allocation_and_stops_the_client_but_keeps_the_entry()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        var handle = coord.Acquire(Cam("a"), "medium");
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        var client = handle.Client;

        handle.Dispose();
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));
        Assert.Equal(VideoState.Idle, client.State);

        using var again = coord.Acquire(Cam("a"), "medium");
        Assert.Same(client, again.Client);
        Assert.True(await svc.WaitFor(c => c.Count(x => x == "create a medium") == 2));
    }

    [Fact]
    public async Task Failed_allocation_marks_the_client_failed_and_retries_with_backoff()
    {
        var svc = new FakeAllocator();
        svc.Grants["medium"] = null;
        using var coord = new VideoStreamCoordinator(svc);

        using var handle = coord.Acquire(Cam("a"), "medium");
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        Assert.Equal(VideoState.Failed, handle.Client.State);

        // First retry after ~1 s.
        Assert.True(await svc.WaitFor(c => c.Count(x => x == "create a medium") == 2, 3000));
        svc.Grants["medium"] = "medium";
        // Second retry after ~2 s more, and this one succeeds — no further creates.
        Assert.True(await svc.WaitFor(c => c.Count(x => x == "create a medium") == 3, 5000));
        await Task.Delay(300);
        Assert.Equal(3, svc.Snapshot().Count(x => x == "create a medium"));
        Assert.DoesNotContain(svc.Snapshot(), x => x.StartsWith("release"));
    }

    [Fact]
    public async Task Allocation_that_completes_after_the_panel_closed_is_released_not_adopted()
    {
        var svc = new FakeAllocator { Gate = new TaskCompletionSource() };
        using var coord = new VideoStreamCoordinator(svc);

        var handle = coord.Acquire(Cam("a"), "medium");
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        handle.Dispose();               // panel closed while the POST is in flight
        svc.Gate.SetResult();

        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));
        svc.Gate = null;
        using var again = coord.Acquire(Cam("a"), "medium");
        // Nothing was adopted, so reopening allocates afresh.
        Assert.True(await svc.WaitFor(c => c.Count(x => x == "create a medium") == 2));
    }

    [Fact]
    public async Task Desire_that_changes_mid_switch_is_applied_afterwards()
    {
        var svc = new FakeAllocator { Gate = new TaskCompletionSource() };
        using var coord = new VideoStreamCoordinator(svc);

        using var handle = coord.Acquire(Cam("a"), "medium");
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium")));
        handle.SetDesiredQuality("high"); // dropped by the in-flight switch, picked up after it
        var gate = svc.Gate;
        svc.Gate = null;
        gate.SetResult();

        Assert.True(await svc.WaitFor(c => c.Contains("create a high")));
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));
    }

    [Fact]
    public async Task Granted_fallback_quality_is_kept_and_released_by_its_own_name()
    {
        var svc = new FakeAllocator();
        svc.Grants["high"] = "low"; // camera has no high substream
        using var coord = new VideoStreamCoordinator(svc);

        var handle = coord.Acquire(Cam("a"), "high");
        Assert.True(await svc.WaitFor(c => c.Contains("create a high")));
        // The granted tier differs from the wanted one; that must not be read
        // as "still not at the wanted quality" and re-allocated in a loop.
        await Task.Delay(300);
        Assert.Equal(1, svc.Snapshot().Count(x => x == "create a high"));
        handle.Dispose();

        Assert.True(await svc.WaitFor(c => c.Contains("release a low")));
        Assert.DoesNotContain("release a high", svc.Snapshot());
    }

    [Fact]
    public async Task Pinned_streams_use_the_pinned_allocation_and_survive_panel_close()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        using var grid = coord.Acquire(Cam("a"), "medium");
        using var pinned = coord.Acquire(Cam("a"), "high", pinned: true);
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium") && c.Contains("create-pinned a high")));
        Assert.NotSame(grid.Client, pinned.Client);

        coord.ReleaseAllExceptPinned();
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium")));
        await Task.Delay(200);
        Assert.DoesNotContain(svc.Snapshot(), x => x.StartsWith("release-pinned"));

        pinned.Dispose();
        Assert.True(await svc.WaitFor(c => c.Contains("release-pinned a high")));
    }

    [Fact]
    public async Task Lenses_are_independent_streams()
    {
        var svc = new FakeAllocator();
        using var coord = new VideoStreamCoordinator(svc);

        using var main = coord.Acquire(Cam("door"), "medium");
        using var package = coord.Acquire(Cam("door"), "package", lens: "package");
        Assert.True(await svc.WaitFor(c => c.Contains("create door medium") && c.Contains("create door package")));
        Assert.NotSame(main.Client, package.Client);

        package.Dispose();
        Assert.True(await svc.WaitFor(c => c.Contains("release door package")));
        Assert.DoesNotContain("release door medium", svc.Snapshot());
    }

    [Fact]
    public async Task Dispose_releases_every_allocation()
    {
        var svc = new FakeAllocator();
        var coord = new VideoStreamCoordinator(svc);
        var a = coord.Acquire(Cam("a"), "medium");
        var b = coord.Acquire(Cam("b"), "high", pinned: true);
        Assert.True(await svc.WaitFor(c => c.Contains("create a medium") && c.Contains("create-pinned b high")));

        coord.Dispose();
        Assert.True(await svc.WaitFor(c => c.Contains("release a medium") && c.Contains("release-pinned b high")));
        Assert.Equal(VideoState.Idle, a.Client.State);
        Assert.Equal(VideoState.Idle, b.Client.State);
    }
}
