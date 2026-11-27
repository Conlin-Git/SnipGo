import AppKit
import Carbon.HIToolbox

enum SettingsKey {
    static let playSound = "playSound"
    static let imageFormat = "imageFormat"            // "png" | "jpg"
    static let recordSystemAudio = "recordSystemAudio"
    static let recordMicrophone = "recordMicrophone"
    static let recordShowCursor = "recordShowCursor"
    static let filePrefix = "filePrefix"
    static let saveDirectory = "saveDirectory"
    static let annotationColor = "annotationColor"    // 颜色索引
    static let annotationSize = "annotationSize"      // 0/1/2
    static let hotKeyCapture = "hotKey.capture"
    static let hotKeyRecord = "hotKey.record"
    static let translateTarget = "translateTarget"   // 上次手动选择的翻译目标语言
}

enum AppSettings {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.playSound: true,
            SettingsKey.imageFormat: "png",
            SettingsKey.recordSystemAudio: false,
            SettingsKey.recordMicrophone: false,
            SettingsKey.recordShowCursor: true,
            SettingsKey.filePrefix: "SnipGo_",
            SettingsKey.saveDirectory: defaultSaveDirectory,
            SettingsKey.annotationColor: 0,
            SettingsKey.annotationSize: 1,
        ])
    }

    static var defaultSaveDirectory: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Desktop"
    }

    static var playSound: Bool { defaults.bool(forKey: SettingsKey.playSound) }
    static var imageFormat: String { defaults.string(forKey: SettingsKey.imageFormat) ?? "png" }
    static var recordSystemAudio: Bool {
        get { defaults.bool(forKey: SettingsKey.recordSystemAudio) }
        set { defaults.set(newValue, forKey: SettingsKey.recordSystemAudio) }
    }
    static var recordMicrophone: Bool {
        get { defaults.bool(forKey: SettingsKey.recordMicrophone) }
        set { defaults.set(newValue, forKey: SettingsKey.recordMicrophone) }
    }
    static var recordShowCursor: Bool { defaults.bool(forKey: SettingsKey.recordShowCursor) }
    static var filePrefix: String { defaults.string(forKey: SettingsKey.filePrefix) ?? "SnipGo_" }
    static var saveDirectory: URL {
        URL(fileURLWithPath: defaults.string(forKey: SettingsKey.saveDirectory) ?? defaultSaveDirectory, isDirectory: true)
    }
    static var annotationColorIndex: Int {
        get { defaults.integer(forKey: SettingsKey.annotationColor) }
        set { defaults.set(newValue, forKey: SettingsKey.annotationColor) }
    }
    static var annotationSize: Int {
        get { defaults.integer(forKey: SettingsKey.annotationSize) }
        set { defaults.set(newValue, forKey: SettingsKey.annotationSize) }
    }
}

// MARK: - 快捷键

enum HotKeyAction: String, CaseIterable {
    case capture
    case record

    var defaultsKey: String {
        switch self {
        case .capture: return SettingsKey.hotKeyCapture
        case .record: return SettingsKey.hotKeyRecord
        }
    }

    var title: String {
        switch self {
        case .capture: return "截图"
        case .record: return "录屏"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .capture: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: [.command, .shift], key: "1")
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: [.command, .shift], key: "2")
        }
    }

    var shortcut: Shortcut? {
        get {
            let d = AppSettings.defaults
            if d.object(forKey: defaultsKey) == nil { return defaultShortcut }
            guard let dict = d.dictionary(forKey: defaultsKey),
                  let code = dict["keyCode"] as? Int,
                  let mods = dict["modifiers"] as? Int,
                  let key = dict["key"] as? String else { return nil } // 存的是空 → 已清除
            return Shortcut(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mods)), key: key)
        }
        nonmutating set {
            if let s = newValue {
                AppSettings.defaults.set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers.rawValue), "key": s.key],
                                         forKey: defaultsKey)
            } else {
                AppSettings.defaults.set([String: Any](), forKey: defaultsKey)
            }
        }
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var key: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
        self.key = key
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    /// 菜单项 keyEquivalent（仅用于显示）
    var menuKeyEquivalent: String { key.count == 1 ? key.lowercased() : "" }

    /// F1–F12
    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(keyCode))
    }

    static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

// MARK: - 标注样式

enum AnnotationPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // 红
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // 橙
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // 黄
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // 绿
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // 蓝
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // 紫
        NSColor.white,
        NSColor.black,
    ]
    static let lineWidths: [CGFloat] = [2, 4, 7]
    static let fontSizes: [CGFloat] = [16, 22, 32]
    static let mosaicWidths: [CGFloat] = [14, 26, 42]

    static func color(_ i: Int) -> NSColor { colors[max(0, min(colors.count - 1, i))] }
}
