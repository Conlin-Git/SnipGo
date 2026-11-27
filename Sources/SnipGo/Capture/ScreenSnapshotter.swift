import AppKit
import ScreenCaptureKit

/// 某块屏幕被冻结时的快照
struct ScreenSnapshot {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage
    /// 屏幕本地坐标（Cocoa，左下角原点，pt）下的窗口矩形，按前后顺序（最前在前）
    let windowRects: [CGRect]
}

enum ScreenSnapshotter {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// CG 全局坐标（左上原点）→ Cocoa 全局坐标（左下原点）
    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    /// 屏幕本地矩形（Cocoa）→ SCStream sourceRect（显示器本地，左上原点）
    static func sourceRect(forLocal r: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 前后顺序的普通窗口（排除本进程、菜单栏、Dock 等）
    static func orderedWindowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [CGRect] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds),
                  r.width >= 40, r.height >= 40 else { continue }
            out.append(cocoaRect(fromCG: r))
        }
        return out
    }

    static func captureAll() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = orderedWindowRects()
        var result: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen),
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rects = windows.compactMap { r -> CGRect? in
                let i = r.intersection(screen.frame)
                guard !i.isNull, i.width > 10, i.height > 10 else { return nil }
                return r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            }
            result.append(ScreenSnapshot(screen: screen, display: display, image: image, windowRects: rects))
        }
        return result
    }

    /// 本应用的 SCRunningApplication，用于把自己的窗口排除在采集之外
    static func filterExcludingSelf(display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let pid = ProcessInfo.processInfo.processIdentifier
        if let me = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        }
        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: mine)
    }
}
