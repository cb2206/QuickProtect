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
/// </summary>
public sealed class VideoStreamCoordinator : IDisposable
{
    private readonly ProtectService _service;
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _entries = new();

    public VideoStreamCoordinator(ProtectService service) => _service = service;

    private sealed class Entry
    {
        public required Camera Camera;
        public required string Key;
        public string? Lens;               // e.g. "package"; null = primary lens
        public bool Pinned;
        public VideoStreamClient Client { get; } = new();
        public Dictionary<object, string> Desires { get; } = new();
        public string? ActiveQuality;      // allocated on the controller
        public int Generation;             // invalidates stale delayed switches
        public bool Switching;
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

    private void Resolve(Entry entry, bool immediate)
    {
        string? want;
        int gen;
        lock (_lock)
        {
            want = entry.Desires.Values.OrderByDescending(Rank).FirstOrDefault();
            gen = ++entry.Generation;
        }

        if (want == null)
        {
            // Last consumer gone: stop and free, keep the entry + last frame.
            entry.Client.Stop();
            ReleaseAllocation(entry);
            return;
        }
        if (want == entry.ActiveQuality) return;

        var isUpgrade = entry.ActiveQuality == null || Rank(want) > Rank(entry.ActiveQuality);
        if (isUpgrade || immediate)
        {
            _ = SwitchAsync(entry, want, gen);
        }
        else
        {
            // Downgrade: settle for 0.6s first (macOS anti-churn behavior).
            _ = Task.Run(async () =>
            {
                await Task.Delay(600);
                lock (_lock)
                {
                    if (entry.Generation != gen) return; // superseded
                }
                await SwitchAsync(entry, want, gen);
            });
        }
    }

    private async Task SwitchAsync(Entry entry, string quality, int gen)
    {
        lock (_lock)
        {
            if (entry.Switching || entry.Generation != gen) return;
            entry.Switching = true;
        }
        try
        {
            // Allocate the new quality BEFORE releasing the old one.
            var result = entry.Pinned
                ? await _service.CreatePinnedStreamUrlAsync(entry.Camera, quality)
                : await _service.CreateRtspStreamUrlAsync(entry.Camera, quality);
            if (result is not { } r) return;

            var old = entry.ActiveQuality;
            entry.ActiveQuality = r.quality;
            entry.Client.Start(FfmpegEngine.MapUrl(r.url)); // Start switches in place when running

            if (old != null && old != r.quality)
            {
                if (entry.Pinned) _service.ReleasePinnedStream(entry.Camera.Id, old);
                else _service.ReleaseStream(entry.Camera.Id, old);
            }
        }
        catch (Exception ex)
        {
            Log.Line($"[Video] quality switch failed for {entry.Camera.Name}: {ex.Message}");
        }
        finally
        {
            lock (_lock) entry.Switching = false;
        }
    }

    private void ReleaseAllocation(Entry entry)
    {
        if (entry.ActiveQuality is not { } q) return;
        entry.ActiveQuality = null;
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
