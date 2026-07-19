import Foundation

/// Pure helpers for the release-asset side of the update check.
///
/// Releases carry one tag per version with assets for every platform
/// (`QuickProtect-1.3.0.dmg`, `QuickProtect-1.3.0-win-x64.exe`, …), so an
/// update is only announced when the running platform's asset is actually
/// present — a release that hasn't received its macOS build yet stays silent.
/// The asset naming convention is a de facto API shared with the .NET port's
/// `UpdateChecker` platform matching; keep the two in sync.
enum UpdateAssets {

    /// True when any asset looks like a macOS download: a `.dmg`, or an
    /// explicit `-macos` tag should the format ever change.
    static func containsMacAsset(_ assetNames: [String]) -> Bool {
        assetNames.contains { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".dmg") || lower.contains("-macos")
        }
    }
}
