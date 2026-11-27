import AppKit

/// 安装后第一次保存图片时，引导用户确认或选择截图保存位置
@MainActor
enum SaveLocationGuide {
    /// 高于钉图（screenSaver - 1），避免引导窗口被钉图挡住
    private static let level = NSWindow.Level.screenSaver

    static var isNeeded: Bool {
        let d = AppSettings.defaults
        if d.bool(forKey: SettingsKey.saveDirectoryConfirmed) { return false }
        // 已在偏好设置里改过保存位置（升级前就设置过的用户）
        if let id = Bundle.main.bundleIdentifier, d.persistentDomain(forName: id)?[SettingsKey.saveDirectory] != nil { return false }
        return true
    }

    static func markConfirmed() {
        AppSettings.defaults.set(true, forKey: SettingsKey.saveDirectoryConfirmed)
    }

    /// 需要时弹出引导。不提供取消：无论怎么选都会继续保存，截图不会丢；
    /// 在文件夹选择框里取消时，本次保存到默认位置，下次保存时再提示。
    static func runIfNeeded() {
        guard isNeeded else { return }
        NSApp.activate(ignoringOtherApps: true)

        let current = AppSettings.saveDirectory
        let name = FileManager.default.displayName(atPath: current.path)
        let alert = NSAlert()
        alert.messageText = "设置截图保存位置"
        alert.informativeText = "这是你第一次保存截图，默认会保存到「\(name)」，也可以选择其他文件夹。\n之后可以在 偏好设置 › 截图保存位置 中修改。"
        alert.addButton(withTitle: "选择文件夹…")
        alert.addButton(withTitle: "使用「\(name)」")
        alert.layout()
        alert.window.level = level

        if alert.runModal() == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "保存到这里"
            panel.message = "选择截图的保存位置"
            panel.directoryURL = current
            panel.level = level
            if panel.runModal() == .OK, let url = panel.url {
                AppSettings.defaults.set(url.path, forKey: SettingsKey.saveDirectory)
                markConfirmed()
            }
        } else {
            markConfirmed()
        }
        // 引导结束后把焦点还给之前的应用（SnipGo 没有常规窗口）
        NSApp.deactivate()
    }
}
