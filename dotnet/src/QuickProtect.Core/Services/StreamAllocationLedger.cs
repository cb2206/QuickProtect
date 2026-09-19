namespace QuickProtect.Core.Services;

/// <summary>Who holds a server-side stream allocation.</summary>
public enum StreamOwner
{
    /// <summary>The panel's grid, focus view and secondary-lens tiles.</summary>
    Panel,

    /// <summary>A pinned floating window.</summary>
    Pinned
}

/// <summary>
/// Decides when a server-side RTSP stream allocation may be released.
///
/// The controller keeps one allocation per camera and quality ("&lt;cameraId&gt;:&lt;quality&gt;")
/// and a DELETE removes it for every consumer: the panel and a pinned window
/// watching the same camera at the same quality share it. Releasing it while
/// the other side still holds it — or is still creating it — kills that side's
/// URL, and a client that reconnects to a deleted URL never recovers. So a
/// DELETE is only due when nobody owns the key and no creation for it is in
/// flight; a release that finds a creation in flight is deferred until that
/// creation ends and sent then only if it failed.
///
/// Thread-safe: creations complete on pool threads, releases come from the UI.
/// </summary>
public sealed class StreamAllocationLedger
{
    private readonly object _lock = new();
    private readonly HashSet<string> _panel = new();
    private readonly HashSet<string> _pinned = new();
    private readonly Dictionary<string, int> _creating = new();
    private readonly HashSet<string> _deferred = new();

    public static string Key(string cameraId, string quality) => $"{cameraId}:{quality}";

    /// <summary>A creation POST for <paramref name="key"/> is about to be sent.</summary>
    public void BeginCreate(string key)
    {
        lock (_lock) _creating[key] = _creating.GetValueOrDefault(key) + 1;
    }

    /// <summary>
    /// A creation POST for <paramref name="key"/> finished. Returns true when a
    /// release deferred during the creation is now due (the creation failed and
    /// nobody else holds the allocation).
    /// </summary>
    public bool EndCreate(string key, StreamOwner owner, bool succeeded)
    {
        lock (_lock)
        {
            if (_creating.TryGetValue(key, out var n) && n > 1) _creating[key] = n - 1;
            else _creating.Remove(key);

            if (succeeded)
            {
                Set(owner).Add(key);
                // The new owner holds the allocation now; its own release deletes it.
                _deferred.Remove(key);
                return false;
            }
            return TakeDeferredIfUnheld(key);
        }
    }

    /// <summary>
    /// <paramref name="owner"/> gives up <paramref name="key"/>. Returns true when
    /// the DELETE should be sent now; false when the owner didn't hold it or the
    /// allocation is still needed.
    /// </summary>
    public bool Release(string key, StreamOwner owner)
    {
        lock (_lock)
        {
            if (!Set(owner).Remove(key)) return false;
            return DueNow(key);
        }
    }

    /// <summary>
    /// <paramref name="owner"/> gives up everything it holds. Returns the keys
    /// whose DELETE should be sent now.
    /// </summary>
    public IReadOnlyList<string> ReleaseAll(StreamOwner owner)
    {
        lock (_lock)
        {
            var set = Set(owner);
            var keys = set.ToArray();
            set.Clear();
            return keys.Where(DueNow).ToArray();
        }
    }

    private HashSet<string> Set(StreamOwner owner) => owner == StreamOwner.Panel ? _panel : _pinned;

    // Caller holds _lock.
    private bool DueNow(string key)
    {
        if (_panel.Contains(key) || _pinned.Contains(key)) return false;
        if (_creating.ContainsKey(key))
        {
            _deferred.Add(key);
            return false;
        }
        return true;
    }

    // Caller holds _lock.
    private bool TakeDeferredIfUnheld(string key)
    {
        if (_creating.ContainsKey(key) || _panel.Contains(key) || _pinned.Contains(key)) return false;
        return _deferred.Remove(key);
    }
}
