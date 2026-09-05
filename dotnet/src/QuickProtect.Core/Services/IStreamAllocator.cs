using QuickProtect.Core.Models;

namespace QuickProtect.Core.Services;

/// <summary>
/// The controller calls the stream coordinator needs: creating and releasing
/// server-side RTSP stream allocations. <see cref="ProtectService"/> is the
/// real implementation; tests substitute a fake.
/// </summary>
public interface IStreamAllocator
{
    /// <summary>
    /// Allocate a stream for the camera at the requested quality, degrading
    /// through the fallback ladder when the tier is unavailable. Returns the
    /// playable URL and the quality that actually succeeded, or null when
    /// every tier failed (rate limit, unreachable controller).
    /// </summary>
    Task<(string url, string quality)?> CreateRtspStreamUrlAsync(Camera camera, string quality = "medium");

    /// <summary>Same as <see cref="CreateRtspStreamUrlAsync"/>, tracked apart for a pinned window.</summary>
    Task<(string url, string quality)?> CreatePinnedStreamUrlAsync(Camera camera, string quality = "high");

    /// <summary>Release one grid/focus allocation (fire-and-forget DELETE).</summary>
    void ReleaseStream(string cameraId, string quality);

    /// <summary>Release one pinned-window allocation.</summary>
    void ReleasePinnedStream(string cameraId, string quality);
}
