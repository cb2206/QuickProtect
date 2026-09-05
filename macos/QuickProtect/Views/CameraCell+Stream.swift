import SwiftUI
import AVFoundation
import AppKit

// MARK: - Stream lifecycle: primary stream, quality switching, secondary lens.

extension CameraCell {

    // MARK: - Stream lifecycle

    /// `force` skips the "already playing" shortcut — required right after a
    /// `disconnect()`, whose `hasFrame = false` lands asynchronously on the RTSP
    /// queue, so a synchronous reconnect would otherwise see a stale `true` and
    /// bail without connecting (e.g. an auto camera staying low on focus).
    /// `keepLastFrame` holds the current frame on the display layer through the
    /// reconnect (a quality switch) instead of flashing grey.
    func startStream(force: Bool = false, keepLastFrame: Bool = false) {
        if !force, rtspClient.hasFrame { mode = .playing; return }
        guard streamTask == nil else { preservingFrame = false; return }
        guard service.isPopoverOpen, camera.isOnline else {
            mode = camera.isOnline ? .connecting : .failed
            return
        }
        mode = .connecting

        let quality = desiredPrimaryQuality
        primaryQuality = quality

        // Stagger connects by grid position so tiles light up as a calm
        // top-left → bottom-right cascade rather than a random scatter. Cap the
        // delay so large grids don't leave the last tiles waiting too long.
        let stagger = UInt64(min(loadOrder, 12)) * 90_000_000

        streamTask = Task {
            try? await Task.sleep(nanoseconds: stagger)
            guard !Task.isCancelled else { return }

            guard let stream = await service.createRtspStreamURL(for: camera, quality: quality.apiValue) else {
                mode = .failed
                preservingFrame = false
                streamTask = nil
                return
            }
            guard !Task.isCancelled else { streamTask = nil; return }

            // Track the quality the server actually served (a fallback may differ
            // from what we asked for) so the next switch releases the right key.
            primaryQuality = StreamQuality(rawValue: stream.quality) ?? quality
            streamTask = nil
            rtspClient.connect(to: stream.url, keepLastFrame: keepLastFrame)
        }
    }

    func stopStream() {
        streamTask?.cancel()
        streamTask = nil
        downSwitchWork?.cancel()
        downSwitchWork = nil
        preservingFrame = false
        rtspClient.disconnect()
        mode = .connecting
    }

    /// Reconnect the primary stream when its effective quality no longer matches
    /// what's playing — an `.auto` camera entering/leaving focus, or the user
    /// changing the per-camera quality. No-op when the resolved quality is
    /// unchanged, so explicit-quality tiles don't churn on focus.
    ///
    /// Upgrades (entering focus) apply immediately so high-res arrives ASAP;
    /// downgrades (leaving focus) are delayed so a quick focus → unfocus → focus
    /// keeps the high stream rather than reconnecting twice. A frozen frame masks
    /// the reconnect either way (see `applyQualitySwitch`).
    func reconcilePrimaryQuality() {
        downSwitchWork?.cancel()
        downSwitchWork = nil
        let desired = desiredPrimaryQuality
        guard desired != primaryQuality else { return }

        let isDowngrade = primaryQuality.map { desired.rank < $0.rank } ?? false
        if isDowngrade {
            let work = DispatchWorkItem { applyQualitySwitch() }
            downSwitchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            applyQualitySwitch()
        }
    }

    /// Switch the primary stream to the now-desired quality — seamlessly when a
    /// picture is on screen: the current session keeps painting while the new
    /// one warms up (`RTSPClient.switchStream`), and the server-side allocations
    /// are settled from the outcome — the replaced quality on success, the
    /// unused new one on abandonment. The new substream is allocated BEFORE the
    /// running one is touched, so an allocation failure just leaves the current
    /// stream playing. Without a live picture there is nothing to hand over, so
    /// it falls back to the plain release-and-reconnect path.
    func applyQualitySwitch() {
        downSwitchWork = nil
        guard rtspClient.hasFrame else {
            let previous = primaryQuality
            preservingFrame = true
            streamTask?.cancel()
            streamTask = nil
            if let previous {
                service.releaseStream(for: camera.id, quality: previous.apiValue)
            }
            // Force past the hasFrame shortcut: a quality change can race the
            // first frame, and a plain startStream() would skip the reconnect.
            startStream(force: true, keepLastFrame: true)
            return
        }

        let previous = primaryQuality
        let desired = desiredPrimaryQuality
        streamTask?.cancel()
        streamTask = nil
        streamTask = Task {
            guard let stream = await service.createRtspStreamURL(for: camera, quality: desired.apiValue) else {
                streamTask = nil
                return
            }
            streamTask = nil
            guard !Task.isCancelled else { return }

            let newQuality = StreamQuality(rawValue: stream.quality) ?? desired
            // Claim the new quality up front so reconcile treats the warm-up as
            // settled instead of starting a second switch; reverted on failure.
            primaryQuality = newQuality
            rtspClient.switchStream(to: stream.url) { success in
                if success {
                    if let previous, previous != newQuality {
                        service.releaseStream(for: camera.id, quality: previous.apiValue)
                    }
                } else {
                    // Warm-up abandoned — the old stream is still live.
                    primaryQuality = previous
                    if newQuality != previous {
                        service.releaseStream(for: camera.id, quality: newQuality.apiValue)
                    }
                }
                // Apply any desire change that raced the handover.
                reconcilePrimaryQuality()
            }
        }
    }

    // MARK: - Secondary lens (package camera) lifecycle

    /// Start or stop the secondary stream to match `wantsSecondaryStream`.
    /// Called whenever focus changes so the grid PiP keeps streaming after the
    /// camera leaves focus (and the focus-only PiP stops).
    func reconcileSecondaryStream() {
        if wantsSecondaryStream { startSecondaryStream() } else { stopSecondaryStream() }
    }

    /// Lazily connect the secondary lens stream when a PiP that needs it is (or
    /// is about to be) visible. No-op for single-lens cameras.
    func startSecondaryStream() {
        guard let lens = camera.secondaryLens, wantsSecondaryStream else { return }
        if secondaryClient.hasFrame { return }
        guard secondaryStreamTask == nil else { return }
        guard service.isPopoverOpen, camera.isOnline else { return }

        startPackagePlaceholderFetch()
        secondaryStreamTask = Task {
            // The package lens is its own quality with no fallback, so the served
            // quality always matches lens.quality — only the URL is needed here.
            guard let stream = await service.createRtspStreamURL(for: camera, quality: lens.quality) else {
                secondaryStreamTask = nil
                return
            }
            guard !Task.isCancelled else { secondaryStreamTask = nil; return }
            secondaryStreamTask = nil
            secondaryClient.connect(to: stream.url)
        }
    }

    /// Panel-close variant of `stopSecondaryStream`: with a keep-alive grace
    /// configured, leave the live stream to the deferred teardown — the client
    /// is owned by RTSPClientManager (disconnectAll) and its allocation stays
    /// in the tracking set (cleanupStreams) — so a quick reopen resumes the
    /// PiP instantly, mirroring the primary stream. Only the in-flight
    /// creation task is cancelled. Tile teardown while the panel stays open
    /// (unfocus, PiP toggled off) stops the stream as before.
    func stopSecondaryStreamUnlessKeptAlive() {
        guard !service.isPopoverOpen, AppSettings.shared.streamKeepAliveSeconds > 0 else {
            stopSecondaryStream()
            return
        }
        secondaryStreamTask?.cancel()
        secondaryStreamTask = nil
        packageSnapshotTask?.cancel()
        packageSnapshotTask = nil
    }

    /// One-shot snapshot fetch that bridges the package stream's keyframe wait:
    /// the placeholder shows in the PiP (or swapped viewport) until the first
    /// decoded frame replaces it. Refreshed on every stream (re)start so a
    /// reopened panel doesn't briefly show a stale scene.
    func startPackagePlaceholderFetch() {
        guard packageSnapshotTask == nil, !secondaryClient.hasFrame else { return }
        packageSnapshotTask = Task {
            let image = await service.fetchPackageSnapshot(for: camera)
            packageSnapshotTask = nil
            guard !Task.isCancelled, let image, !secondaryClient.hasFrame else { return }
            secondaryClient.placeholderImage = image
        }
    }

    /// Disconnect the secondary lens and release its server-side allocation.
    /// Safe to call for single-lens cameras (throwaway client, no allocation).
    func stopSecondaryStream() {
        secondaryStreamTask?.cancel()
        secondaryStreamTask = nil
        packageSnapshotTask?.cancel()
        packageSnapshotTask = nil
        secondaryClient.disconnect()
        if let lens = camera.secondaryLens {
            service.releaseStream(for: camera.id, quality: lens.quality)
        }
        secondaryIsPrimary = false
    }

    /// Swap which lens fills the frame. Both streams stay live, so this is an
    /// instant view reassignment — no reconnect. Resets zoom/pan to the new
    /// primary's natural frame.
    func swapLenses() {
        withAnimation(.easeInOut(duration: 0.2)) { secondaryIsPrimary.toggle() }
        zoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
        reattachNonce &+= 1   // force both stream views to re-attach swapped layers
    }

    /// Label for whichever lens currently sits in the PiP.
    var pipLabel: String {
        secondaryIsPrimary ? camera.name : (camera.secondaryLens?.label ?? "")
    }
}
