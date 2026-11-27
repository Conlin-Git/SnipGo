import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        setupMainMenu()
        setupStatusItem()
        registerHotKeys()
        installKeyMonitor()

        let nc = NotificationCenter.default
        nc.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        nc.addObserver(forName: .shortcutRecordingBegan, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.unregisterAll() }
        }
        nc.addObserver(forName: .shortcutRecordingEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        nc.addObserver(forName: .recordingStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusButton() }
        }

        // 首次启动检查屏幕录制权限（未授权时系统会弹出授权）
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.show()
        return true
    }

    // MARK: - 快捷键

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        var failed: [String] = []
        if let s = HotKeyAction.capture.shortcut,
           !center.register(id: 1, shortcut: s, handler: { [weak self] in self?.captureScreenshot() }) {
            failed.append("截图 \(s.displayString)")
        }
        if let s = HotKeyAction.record.shortcut,
           !center.register(id: 2, shortcut: s, handler: { [weak self] in self?.toggleRecording() }) {
            failed.append("录屏 \(s.displayString)")
        }
        if !failed.isEmpty {
            NSLog("SnipGo: 快捷键注册失败（可能被占用）: \(failed.joined(separator: ", "))")
        }
        rebuildMenu()
    }

    /// 截图/录屏选区期间：Esc 统一取消（文字编辑中除外）
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, CaptureCoordinator.shared.isActive else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event } // 正在输入文字
            CaptureCoordinator.shared.cancel()
            return nil
        }
    }

    // MARK: - 动作

    @objc func captureScreenshot() {
        CaptureCoordinator.shared.start(mode: .screenshot)
    }

    @objc func toggleRecording() {
        if RecordingSession.isRecording {
            RecordingSession.stopCurrent()
        } else {
            CaptureCoordinator.shared.start(mode: .record)
        }
    }

    @objc func openSaveFolder() {
        NSWorkspace.shared.open(AppSettings.saveDirectory)
    }

    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
        rebuildMenu()
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        if let rec = RecordingSession.current {
            // QuickTime 风格：菜单栏显示停止按钮，单击即停止录制
            let img = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "停止录制")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.title = " " + RecordingSession.format(rec.elapsed)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.toolTip = "停止录制"
            statusItem.menu = nil
            button.target = self
            button.action = #selector(toggleRecording)
        } else {
            let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnipGo")
            img?.isTemplate = true
            button.image = img
            button.title = ""
            button.toolTip = "SnipGo"
            button.action = nil
            statusItem.menu = menu
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if RecordingSession.isRecording {
            let stop = NSMenuItem(title: "停止录制", action: #selector(toggleRecording), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            applyShortcut(.record, to: stop)
            menu.addItem(stop)
            menu.addItem(.separator())
        }

        let cap = NSMenuItem(title: "截图", action: #selector(captureScreenshot), keyEquivalent: "")
        cap.target = self
        cap.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        applyShortcut(.capture, to: cap)
        menu.addItem(cap)

        if !RecordingSession.isRecording {
            let rec = NSMenuItem(title: "新建录屏", action: #selector(toggleRecording), keyEquivalent: "")
            rec.target = self
            rec.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            applyShortcut(.record, to: rec)
            menu.addItem(rec)
        }

        let tip = NSMenuItem(title: "长截图：截图后点工具栏中的 ↕ 按钮", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)

        menu.addItem(.separator())
        let folder = NSMenuItem(title: "打开保存目录", action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 SnipGo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func applyShortcut(_ action: HotKeyAction, to item: NSMenuItem) {
        guard let s = action.shortcut, !s.menuKeyEquivalent.isEmpty else { return }
        item.keyEquivalent = s.menuKeyEquivalent
        item.keyEquivalentModifierMask = s.modifiers
    }

    /// 让文字输入框支持 ⌘C / ⌘V / ⌘A 等
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 SnipGo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}
