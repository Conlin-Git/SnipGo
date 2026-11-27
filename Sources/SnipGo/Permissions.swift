import AppKit
import AVFoundation
import CoreGraphics

enum Permissions {
    /// 屏幕录制权限。未授权时触发系统授权并提示。
    @MainActor
    static func ensureScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "需要「屏幕与系统录音」权限"
        alert.informativeText = "请在 系统设置 › 隐私与安全性 › 屏幕与系统录音 中允许 SnipGo，然后重新打开 SnipGo。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    /// 启动时检查屏幕录制权限。
    /// 安装包签名每个版本都不同，更新后系统里原来的授权会失效，但「系统设置」里仍显示已打开，
    /// 用户怎么开关都不生效。所以新版本第一次启动且没有权限时，先删除 SnipGo 的旧授权记录，再重新申请。
    @MainActor
    static func checkScreenCaptureOnLaunch() {
        let key = "lastLaunchedVersion"
        let info = Bundle.main.infoDictionary
        let current = "\(info?["CFBundleShortVersionString"] as? String ?? "")(\(info?["CFBundleVersion"] as? String ?? ""))"
        let last = AppSettings.defaults.string(forKey: key)
        AppSettings.defaults.set(current, forKey: key)
        guard !CGPreflightScreenCaptureAccess() else { return }
        if last != current { resetScreenCaptureRecord() }
        CGRequestScreenCaptureAccess()
    }

    /// 只清除 SnipGo 自己的屏幕录制授权记录（tccutil reset ScreenCapture <本应用 Bundle ID>）
    private static func resetScreenCaptureRecord() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { NSLog("SnipGo: 清除屏幕录制授权失败，退出码 \(p.terminationStatus)") }
        } catch {
            NSLog("SnipGo: 无法运行 tccutil: \(error.localizedDescription)")
        }
    }

    /// 麦克风权限
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
