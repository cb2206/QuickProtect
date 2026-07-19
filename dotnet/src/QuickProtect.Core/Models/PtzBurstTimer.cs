namespace QuickProtect.Core.Models;

/// <summary>
/// Quick-tap minimum-burst timing for PTZ, matching the macOS app: an axis
/// released within <see cref="MinBurst"/> of being pressed has its stop
/// postponed so a fast tap still produces meaningful camera travel
/// (<c>ptzMinBurst = 0.25s</c> in <c>ProtectService.swift</c>). Pure state
/// machine with an explicit clock so it is unit-testable.
/// </summary>
public sealed class PtzBurstTimer
{
    public static readonly TimeSpan MinBurst = TimeSpan.FromSeconds(0.25);

    private enum Axis { Pan, Tilt, Zoom }

    private readonly Dictionary<Axis, DateTime> _startedAt = new();
    private readonly object _lock = new();

    /// <summary>
    /// Records press/release per axis (non-zero starts an axis, 0 releases it,
    /// null leaves it untouched) and returns how long the resulting command
    /// must be postponed so every released axis gets its minimum burst.
    /// </summary>
    public TimeSpan Update(double? pan, double? tilt, double? zoom, DateTime now)
    {
        lock (_lock)
        {
            var delay = TimeSpan.Zero;
            foreach (var (axis, direction) in new[] { (Axis.Pan, pan), (Axis.Tilt, tilt), (Axis.Zoom, zoom) })
            {
                if (direction is not { } d) continue;
                if (d == 0)
                {
                    if (_startedAt.TryGetValue(axis, out var started))
                    {
                        var remaining = MinBurst - (now - started);
                        if (remaining > delay) delay = remaining;
                    }
                    _startedAt.Remove(axis);
                }
                else
                {
                    _startedAt[axis] = now;
                }
            }
            return delay < TimeSpan.Zero ? TimeSpan.Zero : delay;
        }
    }

    /// <summary>Forget all running axes (stop-all paths send immediately).</summary>
    public void Reset()
    {
        lock (_lock) _startedAt.Clear();
    }
}
