import AppKit

/// 应用内更新：查询 GitHub 最新 Release，下载 dmg，校验后替换当前应用并重新打开
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let dmgURL: URL
        let pageURL: URL
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Conlin-Git/SnipGo/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Conlin-Git/SnipGo/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - 检查

    /// 检查更新；发现新版本时弹窗询问是否更新
    func check() {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let release = try await fetchLatest()
                if Self.compare(release.version, Self.currentVersion) == .orderedDescending {
                    state = .available(release)
                    promptInstall(release)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Self.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SnipGo-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Self.error("服务器没有响应") }
        guard http.statusCode == 200 else {
            throw Self.error(http.statusCode == 404 ? "还没有发布任何版本" : "服务器返回 \(http.statusCode)")
        }
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let dmg = p.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw Self.error("最新版本 \(p.tag_name) 没有提供安装包")
        }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        return Release(version: version, notes: p.body ?? "", dmgURL: dmg.browser_download_url, pageURL: p.html_url)
    }

    /// 按数字段比较版本号（1.10.0 > 1.9.2）
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func promptInstall(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        var info = "当前版本 \(Self.currentVersion)。点「立即更新」会自动下载安装包，替换当前应用并重新打开。"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(1200)) }
        info += "\n\n安装包没有经过 Apple 公证，更新后系统可能要求重新允许「屏幕与系统录音」权限。"
        alert.informativeText = info
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "查看发布页")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: download(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    // MARK: - 下载

    func download(_ release: Release) {
        guard !isBusy else { return }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: release.dmgURL) { [weak self] location, response, error in
            // 临时文件在回调返回后会被删除，先移走
            var saved: URL?
            var failure = error?.localizedDescription
            if let location, failure == nil {
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    failure = "服务器返回 \(http.statusCode)"
                } else {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnipGoUpdate-\(UUID().uuidString)")
                    let dest = dir.appendingPathComponent("SnipGo.dmg")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: location, to: dest)
                        saved = dest
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.progressObservation = nil
                self.downloadTask = nil
                if let saved {
                    self.install(dmg: saved, release: release)
                } else {
                    self.state = .failed("下载失败：\(failure ?? "未知错误")")
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let value = p.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(value) }
            }
        }
        downloadTask = task
        task.resume()
    }

    // MARK: - 安装

    private func install(dmg: URL, release: Release) {
        state = .installing
        let target = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Self.extractApp(from: dmg, expectedBundleID: bundleID, expectedVersion: release.version)
                }.value
                try Self.launchReplacer(staged: staged, target: target)
                NSApp.terminate(nil)
            } catch {
                state = .failed("安装失败：\(error.localizedDescription)")
            }
        }
    }

    /// 挂载 dmg，取出其中的 .app 拷到临时目录，校验 Bundle ID 和版本号后卸载
    nonisolated private static func extractApp(from dmg: URL, expectedBundleID: String?, expectedVersion: String) throws -> URL {
        let work = dmg.deletingLastPathComponent()
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let items = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw error("安装包里没有找到应用") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let id = info?["CFBundleIdentifier"] as? String
        let version = info?["CFBundleShortVersionString"] as? String
        guard id != nil, id == expectedBundleID else { throw error("安装包里的应用不是 SnipGo（\(id ?? "未知")）") }
        guard version == expectedVersion else { throw error("安装包版本（\(version ?? "未知")）与发布版本（\(expectedVersion)）不一致") }

        let staged = work.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// 启动替换脚本：先等旧版本退出，再清除旧授权（新版本签名不同，旧授权会失效），然后替换应用并重新打开；替换失败时还原旧版本
    private static func launchReplacer(staged: URL, target: URL) throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw error("没有写入 \(parent.path) 的权限，请到发布页下载安装包手动更新")
        }
        let script = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DST="$3"; BID="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        [ -n "$BID" ] && /usr/bin/tccutil reset ScreenCapture "$BID" >/dev/null 2>&1
        TMP="$DST.updating"; OLD="$DST.old"
        rm -rf "$TMP" "$OLD"
        if ! /usr/bin/ditto "$SRC" "$TMP"; then rm -rf "$TMP"; open "$DST"; exit 1; fi
        if mv "$DST" "$OLD" && mv "$TMP" "$DST"; then
          rm -rf "$OLD"
        else
          [ -d "$DST" ] || mv "$OLD" "$DST"
          rm -rf "$TMP"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        rm -rf "$(dirname "$SRC")"
        open "$DST"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("snipgo-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path,
                       Bundle.main.bundleIdentifier ?? ""]
        try p.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw error("\((tool as NSString).lastPathComponent) 失败：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    nonisolated private static func error(_ message: String) -> NSError {
        NSError(domain: "SnipGo.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
