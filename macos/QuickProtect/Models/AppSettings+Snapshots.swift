import AppKit

// MARK: - Snapshot folder (security-scoped bookmark)

extension AppSettings {

    // MARK: - Snapshot folder

    /// Resolves the saved bookmark to a folder URL, refreshing it if stale.
    /// Returns nil when no folder is configured or the bookmark can't be resolved.
    func resolveSnapshotFolder() -> URL? {
        guard let data = snapshotFolderBookmark else { return nil }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-minting a bookmark needs access to the resource it points at.
                let accessing = url.startAccessingSecurityScopedResource()
                setSnapshotFolder(url)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            return url
        } catch {
            NSLog("[Snapshot] bookmark resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stores a user-picked folder as a security-scoped bookmark, or clears it when nil.
    func setSnapshotFolder(_ url: URL?) {
        guard let url else { snapshotFolderBookmark = nil; return }
        do {
            snapshotFolderBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        } catch {
            NSLog("[Snapshot] bookmark create failed: \(error.localizedDescription)")
        }
    }

    /// Human-readable path of the configured folder, or "" when none is set.
    var snapshotFolderDisplayPath: String {
        if let cached = cachedSnapshotFolderPath { return cached }
        let path = resolveSnapshotFolder()?.path ?? ""
        cachedSnapshotFolderPath = path
        return path
    }
}
