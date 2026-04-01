import Foundation
import AppKit

final class UpdateChecker: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var updateAvailable = false
    @Published var latestVersion   = ""
    @Published var releaseURL: URL?
    @Published var isChecking      = false
    @Published var updateState: UpdateState = .idle

    enum UpdateState: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case error(String)
    }

    // MARK: - Config

    private let repoOwner = "cb2206"
    private let repoName  = "QuickProtect"
    private var timer: Timer?

    // MARK: - Download state

    private var dmgDownloadURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }()

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    // MARK: - Periodic checks

    func startPeriodicChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkForUpdate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    // MARK: - Check for update

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { isChecking = false; return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false

                guard error == nil,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else { return }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = remote
                self.releaseURL = URL(string: htmlURL)
                self.updateAvailable = self.isNewer(remote: remote, local: self.currentVersion)

                // Extract DMG download URL from assets array
                self.dmgDownloadURL = nil
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           name.lowercased().hasSuffix(".dmg"),
                           let downloadURL = asset["browser_download_url"] as? String {
                            self.dmgDownloadURL = URL(string: downloadURL)
                            break
                        }
                    }
                }
            }
        }.resume()
    }

    // MARK: - Download update

    func downloadAndInstall() {
        guard let url = dmgDownloadURL else {
            updateState = .error("No DMG download URL found")
            return
        }
        updateState = .downloading(progress: 0)
        downloadTask = downloadSession.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        updateState = .idle
    }

    // MARK: - Install from DMG

    private func installUpdate(dmgPath: String) {
        updateState = .installing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let appPath = Bundle.main.bundlePath
                let appDir  = (appPath as NSString).deletingLastPathComponent
                _ = (appPath as NSString).lastPathComponent  // "QuickProtect.app"

                // 1. Mount DMG
                let mountPoint = try self?.mountDMG(at: dmgPath)
                guard let mount = mountPoint else {
                    throw UpdateError.mountFailed
                }

                defer {
                    // Always unmount
                    let detach = Process()
                    detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detach.arguments = ["detach", mount, "-force"]
                    try? detach.run()
                    detach.waitUntilExit()
                    // Clean up DMG
                    try? FileManager.default.removeItem(atPath: dmgPath)
                }

                // 2. Find .app in mounted volume
                let contents = try FileManager.default.contentsOfDirectory(atPath: mount)
                guard let appBundle = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw UpdateError.noAppInDMG
                }
                let sourceApp = (mount as NSString).appendingPathComponent(appBundle)

                // 3. Stage: copy new app to temp location using ditto (preserves xattrs)
                let stagedApp = (NSTemporaryDirectory() as NSString).appendingPathComponent("QuickProtect-staged.app")
                try? FileManager.default.removeItem(atPath: stagedApp)
                try self?.runProcess("/usr/bin/ditto", args: [sourceApp, stagedApp])

                // 4. Swap: rename old app, move new app in place
                let oldApp = (appDir as NSString).appendingPathComponent("QuickProtect-old.app")
                try? FileManager.default.removeItem(atPath: oldApp)  // remove any previous backup
                try FileManager.default.moveItem(atPath: appPath, toPath: oldApp)

                do {
                    try FileManager.default.moveItem(atPath: stagedApp, toPath: appPath)
                } catch {
                    // Rollback: restore old app
                    try? FileManager.default.moveItem(atPath: oldApp, toPath: appPath)
                    throw UpdateError.swapFailed(error.localizedDescription)
                }

                // 5. Remove quarantine xattr
                _ = try? self?.runProcess("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", appPath])

                // 6. Restart via helper script
                let pid = ProcessInfo.processInfo.processIdentifier
                self?.launchRestartScript(pid: pid, newAppPath: appPath, oldAppPath: oldApp)

                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }

            } catch {
                DispatchQueue.main.async {
                    self?.updateState = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    private func mountDMG(at path: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", path, "-nobrowse", "-noverify", "-plist"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { throw UpdateError.mountFailed }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.mountFailed
        }

        // Find the mount point from the plist output
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return mountPoint
            }
        }
        throw UpdateError.mountFailed
    }

    @discardableResult
    private func runProcess(_ path: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.processFailed("\(path) failed: \(output)")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func launchRestartScript(pid: Int32, newAppPath: String, oldAppPath: String) {
        let script = """
        #!/bin/sh
        for i in $(seq 1 20); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.5
        done
        rm -rf "\(oldAppPath)"
        open "\(newAppPath)"
        rm -f /tmp/quickprotect-restart.sh
        rm -f /tmp/QuickProtect-update.dmg
        """

        let scriptPath = "/tmp/quickprotect-restart.sh"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptPath]
        // Detach from our process group so it survives our exit
        proc.qualityOfService = .utility
        try? proc.run()
    }

    // MARK: - Version comparison

    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case mountFailed
        case noAppInDMG
        case swapFailed(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .mountFailed:        return "Failed to mount the update DMG"
            case .noAppInDMG:         return "No app bundle found in the DMG"
            case .swapFailed(let m):  return "App replacement failed: \(m)"
            case .processFailed(let m): return m
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateChecker: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        updateState = .downloading(progress: progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = "/tmp/QuickProtect-update.dmg"
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: dest))
            installUpdate(dmgPath: dest)
        } catch {
            updateState = .error("Failed to save download: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            updateState = .error("Download failed: \(error.localizedDescription)")
        }
    }
}
