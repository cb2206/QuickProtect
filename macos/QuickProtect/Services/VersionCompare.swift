import Foundation

/// Version-string comparison for the update checker. Lives on its own (not in
/// the RTP parser, where it used to sit for test-target convenience) and is
/// mirrored by the .NET app's `VersionCompare`.
enum VersionCompare {

    /// True when `remote` is a newer version than `local`.
    ///
    /// Numeric dot components compare left to right with missing components
    /// treated as 0 (`1` == `1.0.0`). A pre-release suffix (`1.4.0-beta.2`)
    /// sorts *before* the same numeric version without one, and two
    /// pre-releases of the same version compare by their suffix, so a beta tag
    /// never announces itself as an update over the matching release.
    static func isNewer(remote: String, local: String) -> Bool {
        let r = parse(remote)
        let l = parse(local)
        for i in 0..<max(r.numbers.count, l.numbers.count) {
            let rv = i < r.numbers.count ? r.numbers[i] : 0
            let lv = i < l.numbers.count ? l.numbers[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        switch (r.prerelease, l.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return true        // release beats its own pre-release
        case (.some, nil): return false
        case (let rp?, let lp?): return rp.compare(lp, options: .numeric) == .orderedDescending
        }
    }

    private struct Parsed {
        let numbers: [Int]
        let prerelease: String?
    }

    private static func parse(_ version: String) -> Parsed {
        // Drop build metadata ("+build.7") entirely; split off "-prerelease".
        let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        let core = parts.first.map(String.init) ?? ""
        let prerelease = parts.count > 1 ? String(parts[1]) : nil
        let numbers = core.split(separator: ".").map { Int($0) ?? 0 }
        return Parsed(numbers: numbers, prerelease: prerelease)
    }
}
