import Foundation
import Combine
import CoreGraphics

/// Merges every configured site's `ProtectService` into the one camera list
/// the UI shows, and routes each per-camera call (streams, PTZ, snapshots) to
/// the console that camera belongs to. Also holds the panel-wide UI state
/// (popover open, focus mode) that used to live on the single service.
///
/// A site that fails (unreachable, rejected key, changed certificate) drops
/// out of the merged list and is reported in `siteIssues`; the grid only
/// gives way to a full-screen state card when no site is usable.
@MainActor
final class ProtectHub: ObservableObject {

    /// A site that currently contributes no cameras, and why.
    struct SiteIssue: Identifiable, Equatable {
        let siteID: String
        let siteName: String
        let message: String
        let isCertificateChange: Bool
        var id: String { siteID }
    }

    /// What the grid area shows.
    enum GridState: Equatable {
        case loading
        case certificateChanged
        case error(String)
        case empty
        case cameras
    }

    /// Cameras from every healthy site, in site order (layout profiles then
    /// apply the user's order). A camera id seen twice — the same console
    /// added as two sites — is kept once.
    @Published private(set) var cameras: [Camera] = []
    /// Any site is fetching (header spinner).
    @Published private(set) var isLoading = false
    /// Every site is fetching (the grid shows the connecting card).
    @Published private(set) var isLoadingAll = false
    @Published private(set) var siteIssues: [SiteIssue] = []
    /// PTZ-only problems from any site, surfaced as a toast on the focused camera.
    @Published var ptzErrorMessage: String?
    /// Set by AppDelegate when the popover opens/closes so cells can pause players.
    @Published var isPopoverOpen = false
    /// True while a camera is focused (single-camera view). Drives the popover
    /// header swap so the camera's own top bar replaces the grid header.
    @Published var isFocusMode = false
    /// Remembers which camera was focused so it can be restored when the panel reopens.
    var lastFocusedCameraId: String?

    /// A site's address or API key is about to change (fires before the new
    /// value is stored, so teardown still addresses the old controller).
    let connectionWillChange = PassthroughSubject<String, Never>()
    /// A site was removed; its pinned windows should close.
    let siteRemoved = PassthroughSubject<String, Never>()

    private let settings: AppSettings
    private let makeService: (ControllerSite) -> ProtectService
    private(set) var sites: [ControllerSite] = []
    private var services: [String: ProtectService] = [:]
    private var subscriptions: [String: Set<AnyCancellable>] = [:]
    private var sitesSubscription: AnyCancellable?
    /// Last known site of every camera any service listed — including those
    /// of a currently failing site, so their streams can still be released.
    private var siteForCamera: [String: String] = [:]

    init(settings: AppSettings = .shared, makeService: ((ControllerSite) -> ProtectService)? = nil) {
        self.settings = settings
        self.makeService = makeService ?? { ProtectService(settings: $0, siteID: $0.id) }
        reconcileServices(with: settings.sites)
        // @Published delivers the new array before it is stored, so the
        // reconcile works from the emitted value, never `settings.sites`.
        sitesSubscription = settings.$sites.dropFirst().sink { [weak self] sites in
            self?.reconcileServices(with: sites)
        }
    }

    // MARK: - Services per site

    func service(forSite id: String) -> ProtectService? { services[id] }

    func service(for camera: Camera) -> ProtectService? {
        services[camera.siteID] ?? service(forCameraID: camera.id)
    }

    func service(forCameraID id: String) -> ProtectService? {
        siteForCamera[id].flatMap { services[$0] }
    }

    func site(for camera: Camera) -> ControllerSite? {
        let id = camera.siteID.isEmpty ? siteForCamera[camera.id] : camera.siteID
        return sites.first { $0.id == id }
    }

    /// Site label for a camera's tile badge; nil while only one site exists.
    func siteBadge(for camera: Camera) -> String? {
        guard sites.count > 1 else { return nil }
        return site(for: camera)?.displayName
    }

    private func reconcileServices(with newSites: [ControllerSite]) {
        let ids = Set(newSites.map(\.id))
        for (id, service) in services where !ids.contains(id) {
            siteRemoved.send(id)
            service.cancelFetch()
            service.cleanupStreams()
            service.cleanupPinnedStreams()
            services[id] = nil
            subscriptions[id] = nil
        }
        for site in newSites where services[site.id] == nil {
            let service = makeService(site)
            services[site.id] = service
            subscribe(service, site: site)
        }
        sites = newSites
        recompute()
    }

    private func subscribe(_ service: ProtectService, site: ControllerSite) {
        var bag = Set<AnyCancellable>()
        // objectWillChange fires before the change lands; the run-loop hop
        // reads the settled values.
        service.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &bag)
        site.$name.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &bag)
        service.$ptzErrorMessage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak service] message in
                self?.ptzErrorMessage = message
                service?.ptzErrorMessage = nil
            }
            .store(in: &bag)
        let siteID = site.id
        site.connectionChanges
            .sink { [weak self] in self?.connectionWillChange.send(siteID) }
            .store(in: &bag)
        subscriptions[site.id] = bag
    }

    // MARK: - Merged state

    /// Rebuilds the merged camera list, loading flags and per-site issues.
    /// Also distributes a newly added site's first cameras over the layout
    /// profiles (see `AppSettings.seedSiteCamerasIfNeeded`).
    func recompute() {
        var merged: [Camera] = []
        var seen = Set<String>()
        var map: [String: String] = [:]
        var issues: [SiteIssue] = []
        var anyLoading = false
        var allLoading = !sites.isEmpty

        for site in sites {
            guard let service = services[site.id] else { continue }
            anyLoading = anyLoading || service.isLoading
            allLoading = allLoading && service.isLoading
            for cam in service.cameras where map[cam.id] == nil { map[cam.id] = site.id }

            if service.certificateChange != nil {
                issues.append(SiteIssue(siteID: site.id, siteName: site.displayName,
                                        message: ProtectService.certificateChangedMessage,
                                        isCertificateChange: true))
                continue
            }
            if let error = service.errorMessage {
                issues.append(SiteIssue(siteID: site.id, siteName: site.displayName,
                                        message: error, isCertificateChange: false))
                continue
            }
            for cam in service.cameras where seen.insert(cam.id).inserted {
                merged.append(cam)
            }
            settings.seedSiteCamerasIfNeeded(siteID: site.id, cameraIDs: service.cameras.map(\.id))
        }

        siteForCamera = map
        if !Self.sameCameras(merged, cameras) { cameras = merged }
        if isLoading != anyLoading { isLoading = anyLoading }
        if isLoadingAll != allLoading { isLoadingAll = allLoading }
        if siteIssues != issues { siteIssues = issues }
    }

    /// Camera has no Equatable (its channel list doesn't need one); compare
    /// what the UI renders so unrelated service changes don't republish.
    private static func sameCameras(_ lhs: [Camera], _ rhs: [Camera]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.name == b.name && a.state == b.state && a.siteID == b.siteID
                && a.isPtz == b.isPtz && a.canZoom == b.canZoom && a.secondaryLens == b.secondaryLens
                && a.channels.count == b.channels.count
        }
    }

    /// What the grid shows. With one site this is exactly the old
    /// single-controller behaviour; with several, a failing site only shows
    /// as a banner while another still delivers cameras.
    /// Cameras already on screen outrank a refresh in flight (every panel open
    /// refetches): swapping in the loading card would tear down every tile —
    /// cancelling stream requests mid-POST and fully stopping kept-alive
    /// secondary streams — only to rebuild them a moment later. The header's
    /// refresh spinner shows the refetch instead.
    var gridState: GridState {
        if !cameras.isEmpty { return .cameras }
        if isLoading { return .loading }
        if siteIssues.contains(where: \.isCertificateChange) { return .certificateChanged }
        if let message = combinedErrorMessage { return .error(message) }
        return .empty
    }

    /// The issue text for the full error card: the bare message with one
    /// site, otherwise one "Site: message" line per failing site.
    var combinedErrorMessage: String? {
        let errors = siteIssues.filter { !$0.isCertificateChange }
        guard !errors.isEmpty else { return nil }
        if sites.count == 1 { return errors[0].message }
        return errors.map { "\($0.siteName): \($0.message)" }.joined(separator: "\n")
    }

    /// The first site whose certificate change awaits review.
    var pendingCertificateService: ProtectService? {
        sites.lazy.compactMap { self.services[$0.id] }.first { $0.certificateChange != nil }
    }

    // MARK: - Fan-out

    /// Fetches every site's camera list concurrently (each service coalesces
    /// and throttles on its own).
    func fetchCameras(forced: Bool = false) async {
        let all = sites.compactMap { services[$0.id] }
        await withTaskGroup(of: Void.self) { group in
            for service in all {
                group.addTask { await service.fetchCameras(forced: forced) }
            }
        }
        recompute()
    }

    func refetchForNewConnection(siteID: String) async {
        await services[siteID]?.refetchForNewConnection()
        recompute()
    }

    func cancelFetch() {
        services.values.forEach { $0.cancelFetch() }
    }

    func cleanupStreams() {
        services.values.forEach { $0.cleanupStreams() }
    }

    func cleanupPinnedStreams() {
        services.values.forEach { $0.cleanupPinnedStreams() }
    }

    /// Waits up to `timeout` in total (not per site) for pending releases.
    func waitForStreamReleases(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        for service in services.values {
            service.waitForStreamReleases(timeout: max(0, deadline.timeIntervalSinceNow))
        }
    }

    /// Trusts `host`'s pending certificate through the service(s) that use it,
    /// so their cards clear and their streams reconnect.
    func trustPendingCertificate(host: String) {
        let matching = services.values.filter { $0.certificateChange?.host == host }
        if matching.isEmpty {
            // A pin under another key format (listed in Settings) — any service
            // can promote it in the shared store.
            sites.first.flatMap { services[$0.id] }?.trustPendingCertificate(host: host)
        } else {
            matching.forEach { $0.trustPendingCertificate(host: host) }
        }
    }

    // MARK: - Per-camera routing

    func controllerAddress(for camera: Camera) -> ControllerAddress? {
        service(for: camera)?.controllerAddress
    }

    func createRtspStreamURL(for camera: Camera,
                             quality: String = "medium") async -> (url: URL, quality: String)? {
        await service(for: camera)?.createRtspStreamURL(for: camera, quality: quality)
    }

    func releaseStream(for cameraId: String, quality: String) {
        service(forCameraID: cameraId)?.releaseStream(for: cameraId, quality: quality)
    }

    func fetchPackageSnapshot(for camera: Camera) async -> CGImage? {
        await service(for: camera)?.fetchPackageSnapshot(for: camera)
    }

    func fetchCameraSnapshot(for camera: Camera) async -> CGImage? {
        await service(for: camera)?.fetchCameraSnapshot(for: camera)
    }

    func ptzSetAxes(cameraId: String, pan: Double? = nil, tilt: Double? = nil, zoom: Double? = nil) {
        service(forCameraID: cameraId)?.ptzSetAxes(cameraId: cameraId, pan: pan, tilt: tilt, zoom: zoom)
    }

    func ptzStopAll(cameraId: String) {
        service(forCameraID: cameraId)?.ptzStopAll(cameraId: cameraId)
    }
}
