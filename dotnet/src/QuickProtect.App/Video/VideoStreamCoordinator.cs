using QuickProtect.Core.Models;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Video;

/// <summary>
/// Owns one <see cref="VideoStreamClient"/> per camera lens and coordinates the
/// server-side stream allocations — the port of the macOS RTSPClientManager
/// behaviors that make the app feel fast:
///
///  • Clients are keyed by camera+lens and survive view transitions, so the
///    focus view adopts the already-running grid stream instantly and the grid
///    reappears with live frames when focus exits.
///  • Consumers declare a desired quality; the effective quality is the highest
///    across consumers. Upgrades switch immediately (keeping the last frame on
///    screen), downgrades wait 0.6s to avoid churn.
///  • Quality switches allocate the new stream before releasing the old one,
///    so an async release can never kill the fresh allocation.
///  • When the last consumer releases, the client stops and the allocation is
///    freed, but the entry (with its last frame) is kept — reopening the panel
///    shows the previous frame immediately while the stream reconnects.
///  • A desire that changes while a switch is in flight is re-resolved once the
///    switch completes; a failed allocation (rate limit, unreachable controller)
///    is retried with backoff and the tile is told so it can drop its spinner.
///
/// Entry state (<c>ActiveQuality</c>, <c>Switching</c>, <c>Generation</c>) is
/// only touched under <c>_lock</c>.
/// </summary>
public sealed class VideoStreamCoordinator : IDisposable
{
    private readonly IStreamAllocator _service;
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _entries = new();

    private static readonly TimeSpan DowngradeSettle = TimeSpan.FromMilliseconds(600);
    private static readonly TimeSpan RetryInitial = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan RetryMax = TimeSpan.FromSeconds(30);

    public VideoStreamCoordinator(IStreamAllocator service) => _service = service;

    private sealed class Entry
    {
        public required Camera Camera;
        public required string Key;
        public string? Lens;               // e.g. "package"; null = primary lens
        public bool Pinned;
        public VideoStreamClient Client { get; } = new();
        public Dictionary<object, string> Desires { get; } = new();
        public string? RequestedQuality;   // tier the coordinator asked for (desires compare to this)
        public string? ActiveQuality;      // tier the controller granted (may be a fallback; released by this name)
        public int Generation;             // invalidates stale delayed switches and retries
        public bool Switching;
        public TimeSpan RetryDelay = RetryInitial;
    }

    /// <summary>A consumer's claim on a stream. Dispose to release.</summary>
    public sealed class Handle : IDisposable
    {
        private VideoStreamCoordinator? _owner;
        internal string Key = "";
        internal object Token = new();
        public VideoStreamClient Client { get; internal set; } = null!;

        internal Handle(VideoStreamCoordinator owner) => _owner = owner;

        /// <summary>Change this consumer's desired quality (e.g. grid → focus).</summary>
        public void SetDesiredQuality(string quality) => _owner?.UpdateDesire(this, quality);

        public void Dispose()
        {
            var o = _owner;
            _owner = null;
            o?.Release(this);
        }
    }

    /// <summary>
    /// Acquire the shared stream for <paramref name="camera"/> at the given
    /// desired quality. Streaming starts (or upgrades) as needed; the handle's
    /// client may already hold a frame from a previous session.
    /// </summary>
    public Handle Acquire(Camera camera, string quality, string? lens = null, bool pinned = false)
    {
        var key = $"{camera.Id}|{lens ?? "primary"}{(pinned ? "|pin" : "")}";
        Handle handle;
        Entry entry;
        lock (_lock)
        {
            if (!_entries.TryGetValue(key, out entry!))
            {
                entry = new Entry { Camera = camera, Key = key, Lens = lens, Pinned = pinned };
                _entries[key] = entry;
            }
            entry.Camera = camera; // keep enrichment (PTZ flags, online state) fresh
            handle = new Handle(this) { Key = key, Client = entry.Client };
            entry.Desires[handle.Token] = quality;
        }
        Resolve(entry, immediate: true);
        return handle;
    }

    private void UpdateDesire(Handle handle, string quality)
    {
        Entry? entry;
        lock (_lock)
        {
            if (!_entries.TryGetValue(handle.Key, out entry)) return;
            entry.Desires[handle.Token] = quality;
        }
        Resolve(entry, immediate: false);
    }

    private void Release(Handle handle)
    {
        Entry? entry;
        lock (_lock)
        {
            if (!_entries.TryGetValue(handle.Key, out entry)) return;
            entry.Desires.Remove(handle.Token);
        }
        Resolve(entry, immediate: false);
    }

    /// <summary>
    /// Pause or resume display decode on every non-pinned stream (stream
    /// keep-alive grace — pinned windows stay visible and keep decoding).
    /// The macOS analog is RTSPClientManager.setRenderPaused.
    /// </summary>
    public void SetRenderPaused(bool paused)
    {
        List<VideoStreamClient> clients;
        lock (_lock) clients = _entries.Values.Where(e => !e.Pinned).Select(e => e.Client).ToList();
        foreach (var client in clients) client.SetRenderPaused(paused);
    }

    /// <summary>Stop every non-pinned stream and free its allocation (panel closed).</summary>
    public void ReleaseAllExceptPinned()
    {
        List<Entry> entries;
        lock (_lock) entries = _entries.Values.Where(e => !e.Pinned).ToList();
        foreach (var e in entries)
        {
            lock (_lock) e.Desires.Clear();
            Resolve(e, immediate: true);
        }
    }

    // MARK: - Effective-quality resolution

    private static int Rank(string quality) => quality switch
    {
        "low" => 0,
        "medium" => 1,
        "high" => 2,
        _ => 3 // fixed lenses ("package") never compete
    };

    private static string? Wanted(Entry entry)
        => entry.Desires.Values.OrderByDescending(Rank).FirstOrDefault();

    private void Resolve(Entry entry, bool immediate)
    {
        string? want, active;
        int gen;
        lock (_lock)
        {
            want = Wanted(entry);
            // Compare against what was asked for, not what the controller
            // granted: a camera without the wanted substream answers with a
            // fallback tier, and re-resolving on that would loop forever.
            active = entry.RequestedQuality;
            gen = ++entry.Generation;
        }

        if (want == null)
        {
            // Last consumer gone: stop and free, keep the entry + last frame.
            entry.Client.Stop();
            ReleaseAllocation(entry);
            return;
        }
        if (want == active) return;

        var isUpgrade = active == null || Rank(want) > Rank(active);
        if (isUpgrade || immediate)
        {
            _ = SwitchAsync(entry, want, gen);
        }
        else
        {
            // Downgrade: settle first (macOS anti-churn behavior).
            _ = SwitchLater(entry, want, gen, DowngradeSettle);
        }
    }

    private async Task SwitchLater(Entry entry, string quality, int gen, TimeSpan delay)
    {
        await Task.Delay(delay);
        lock (_lock)
        {
            if (entry.Generation != gen) return; // superseded
        }
        await SwitchAsync(entry, quality, gen);
    }

    private async Task SwitchAsync(Entry entry, string quality, int gen)
    {
        lock (_lock)
        {
            if (entry.Switching || entry.Generation != gen) return;
            entry.Switching = true;
        }
        // True once this switch reached a settled state (started, or abandoned
        // because nobody wants the stream any more). A failed allocation is
        // retried with backoff instead of re-resolving in a tight loop.
        var settled = false;
        try
        {
            // Allocate the new quality BEFORE releasing the old one.
            var result = entry.Pinned
                ? await _service.CreatePinnedStreamUrlAsync(entry.Camera, quality)
                : await _service.CreateRtspStreamUrlAsync(entry.Camera, quality);
            if (result is not { } r)
            {
                ScheduleRetry(entry, quality, gen);
                return;
            }

            // The last consumer may have released while the POST was in flight
            // (panel closed): adopting the allocation now would leak it
            // server-side — release it instead and leave the client stopped.
            bool abandoned;
            lock (_lock) abandoned = entry.Desires.Count == 0;
            if (abandoned)
            {
                if (entry.Pinned) _service.ReleasePinnedStream(entry.Camera.Id, r.quality);
                else _service.ReleaseStream(entry.Camera.Id, r.quality);
                settled = true;
                return;
            }

            string? old;
            lock (_lock)
            {
                old = entry.ActiveQuality;
                entry.RequestedQuality = quality;
                entry.ActiveQuality = r.quality;
                entry.RetryDelay = RetryInitial;
            }
            if (old != null && old != r.quality)
            {
                // Seamless switch: the client keeps the old session decoding
                // (live picture) until the new one paints its first frame.
                // Releasing the old allocation any earlier would kill that
                // session server-side and freeze the picture for the handover.
                var pinned = entry.Pinned;
                var cameraId = entry.Camera.Id;
                entry.Client.Start(FfmpegEngine.MapUrl(r.url), onPreviousSessionEnded: () =>
                {
                    if (pinned) _service.ReleasePinnedStream(cameraId, old);
                    else _service.ReleaseStream(cameraId, old);
                });
            }
            else
            {
                entry.Client.Start(FfmpegEngine.MapUrl(r.url));
            }
            settled = true;
        }
        catch (Exception ex)
        {
            Log.Line($"[Video] quality switch failed for {entry.Camera.Name}: {ex.Message}");
            ScheduleRetry(entry, quality, gen);
        }
        finally
        {
            string? wantNow = null, requestedNow = null;
            lock (_lock)
            {
                entry.Switching = false;
                if (settled)
                {
                    wantNow = Wanted(entry);
                    requestedNow = entry.RequestedQuality;
                }
            }
            // A desire that arrived mid-switch was dropped at the top of
            // SwitchAsync (Switching was true) — pick it up now.
            if (settled && wantNow != requestedNow) Resolve(entry, immediate: true);
        }
    }

    /// <summary>
    /// A failed allocation (429/5xx, unreachable controller) is retried with
    /// exponential backoff while the desire stands. The tile is told so its
    /// spinner doesn't stay up forever; the last frame (if any) stays on screen.
    /// </summary>
    private void ScheduleRetry(Entry entry, string quality, int gen)
    {
        TimeSpan delay;
        lock (_lock)
        {
            delay = entry.RetryDelay;
            entry.RetryDelay = TimeSpan.FromTicks(Math.Min(entry.RetryDelay.Ticks * 2, RetryMax.Ticks));
        }
        entry.Client.ReportFailure();
        Log.Line($"[Video] allocation failed for {entry.Camera.Name}; retrying in {delay.TotalSeconds:0.#}s");
        _ = SwitchLater(entry, quality, gen, delay);
    }

    private void ReleaseAllocation(Entry entry)
    {
        string? q;
        lock (_lock)
        {
            q = entry.ActiveQuality;
            entry.ActiveQuality = null;
            entry.RequestedQuality = null;
        }
        if (q == null) return;
        if (entry.Pinned) _service.ReleasePinnedStream(entry.Camera.Id, q);
        else _service.ReleaseStream(entry.Camera.Id, q);
    }

    public void Dispose()
    {
        List<Entry> entries;
        lock (_lock) { entries = _entries.Values.ToList(); _entries.Clear(); }
        foreach (var e in entries)
        {
            e.Client.Dispose();
            ReleaseAllocation(e);
        }
    }
}
