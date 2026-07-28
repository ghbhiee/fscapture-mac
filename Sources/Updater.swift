import AppKit

/// Lightweight self-hosted auto-updater. On launch (and on demand) it fetches a
/// small `version.json` from the update host, compares the version to this
/// build, and — if newer — offers to download a signed .app zip, swap it into
/// place, and relaunch. No external dependencies; relies on the app being
/// signed with the shared stable "Hongbo Dev" identity so TCC grants survive.
@MainActor
enum Updater {
    /// Where the version manifest and release zips live.
    static let manifestURL = URL(string: "https://www.tokencv.com/fscapture/version.json")!

    struct Manifest: Decodable {
        let version: String        // e.g. "0.2.0"
        let url: String            // https://…/FSCapture-0.2.0.zip
        let notes: String?
        let minSystemVersion: String?
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Check on launch, quietly (no alert if up to date or on network error).
    static func checkOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check(silent: true) }
    }

    /// Manual "Check for Updates…" — reports even when already current.
    static func checkManually() { check(silent: false) }

    private static func check(silent: Bool) {
        var req = URLRequest(url: manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data, error == nil,
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                if !silent {
                    DispatchQueue.main.async {
                        OutputRouter.notifyHUD(Loc.t("检查更新失败", "Update check failed"))
                    }
                }
                return
            }
            DispatchQueue.main.async {
                if isNewer(manifest.version, than: currentVersion) {
                    presentUpdate(manifest)
                } else if !silent {
                    OutputRouter.notifyHUD(Loc.t("已是最新版本 \(currentVersion)",
                                                 "You're on the latest version \(currentVersion)"))
                }
            }
        }.resume()
    }

    /// Semantic-ish comparison of dotted version strings.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func presentUpdate(_ manifest: Manifest) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = Loc.t("发现新版本 \(manifest.version)", "New version \(manifest.version) available")
        var info = Loc.t("当前版本 \(currentVersion)。是否现在更新？",
                         "You have \(currentVersion). Update now?")
        if let notes = manifest.notes, !notes.isEmpty { info += "\n\n" + notes }
        alert.informativeText = info
        alert.addButton(withTitle: Loc.t("更新并重启", "Update & Relaunch"))
        alert.addButton(withTitle: Loc.t("稍后", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: manifest.url) else { return }
        download(url)
    }

    private static func download(_ url: URL) {
        OutputRouter.notifyHUD(Loc.t("正在下载更新…", "Downloading update…"))
        URLSession.shared.downloadTask(with: url) { tmp, _, error in
            guard let tmp, error == nil else {
                DispatchQueue.main.async { OutputRouter.notifyHUD(Loc.t("下载失败", "Download failed")) }
                return
            }
            // Move to a stable temp path with a .zip suffix.
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent("FSCapture-update-\(UUID().uuidString).zip")
            try? FileManager.default.moveItem(at: tmp, to: zip)
            DispatchQueue.main.async { installAndRelaunch(zip: zip) }
        }.resume()
    }

    private static func installAndRelaunch(zip: URL) {
        let appPath = Bundle.main.bundlePath
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSCapture-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Unzip.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, workDir.path]
        do { try unzip.run(); unzip.waitUntilExit() } catch {
            OutputRouter.notifyHUD(Loc.t("解压失败", "Unzip failed")); return
        }
        guard unzip.terminationStatus == 0,
              let newApp = findApp(in: workDir) else {
            OutputRouter.notifyHUD(Loc.t("更新包无效", "Invalid update package")); return
        }

        // A detached shell script waits for us to quit, swaps the bundle, relaunches.
        let script = """
        #!/bin/sh
        sleep 1
        for i in $(seq 1 40); do
            pgrep -f "FSCapture.app/Contents/MacOS/FSCapture" >/dev/null || break
            sleep 0.5
        done
        rm -rf "\(appPath)"
        /usr/bin/ditto "\(newApp.path)" "\(appPath)"
        rm -rf "\(workDir.path)" "\(zip.path)"
        open "\(appPath)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fscapture-update-\(UUID().uuidString).sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path]
        do { try task.run() } catch {
            OutputRouter.notifyHUD(Loc.t("更新启动失败", "Failed to start update")); return
        }
        OutputRouter.notifyHUD(Loc.t("正在安装并重启…", "Installing and relaunching…"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    private static func findApp(in dir: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }
}
