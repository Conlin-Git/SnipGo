import AppKit
import NaturalLanguage
import SnipCore
import SwiftUI
import Translation

// MARK: - 语言工具

enum TranslateLanguages {
    /// 常用语言放在列表前面
    static let common = ["zh-Hans", "en", "ja", "ko", "zh-Hant"]

    /// 统一成「语言代码」或「zh-Hans / zh-Hant」形式的标识，便于比较和存储
    static func normalizedID(_ l: Locale.Language) -> String? {
        guard let code = l.languageCode?.identifier, code != "und" else { return nil }
        guard code == "zh" else { return code }
        let hant = l.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(l.region?.identifier ?? "")
        return hant ? "zh-Hant" : "zh-Hans"
    }

    static func normalizedID(_ nl: NLLanguage?) -> String? {
        guard let nl, nl != .undetermined else { return nil }
        return normalizedID(Locale.Language(identifier: nl.rawValue))
    }

    static func displayName(_ id: String) -> String {
        switch id {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁体中文"
        default: return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: id) ?? id
        }
    }

    static func isChinese(_ id: String?) -> Bool { id?.hasPrefix("zh") == true }

    /// 默认目标语言：优先用上次手动选择的；原文是中文且上次选的也是中文时改用英文；没选过时 中文→英文、其他→简体中文
    static func defaultTarget(forSource source: String?) -> String {
        if let saved = AppSettings.defaults.string(forKey: SettingsKey.translateTarget), !saved.isEmpty {
            if !(isChinese(source) && isChinese(saved)) && saved != source { return saved }
        }
        return isChinese(source) ? "en" : "zh-Hans"
    }
}

// MARK: - 模型

@MainActor
final class TextPanelModel: ObservableObject {
    enum Mode { case recognize, translate }

    @Published private(set) var mode: Mode
    @Published private(set) var isRecognizing = true
    @Published private(set) var recognizeError: String?
    @Published var sourceText = ""
    @Published private(set) var sourceLanguage: String?
    @Published var translatedText = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var translateError: String?
    @Published private(set) var target: String
    @Published private(set) var targetOptions: [String] = TranslateLanguages.common
    @Published var config: TranslationSession.Configuration?
    @Published private(set) var lastTranslatedSource: String?
    @Published private(set) var hint: String?

    var onModeChange: ((Mode) -> Void)?
    private var userPickedTarget = false
    private var hintTask: Task<Void, Never>?

    init(image: CGImage, translate: Bool) {
        mode = translate ? .translate : .recognize
        target = TranslateLanguages.defaultTarget(forSource: nil)
        Task { await recognize(image) }
        Task { await loadTargetOptions() }
    }

    var hasText: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRetranslate: Bool { hasText && !isTranslating && sourceText != lastTranslatedSource }

    private func recognize(_ image: CGImage) async {
        do {
            let text = try await TextRecognizer.recognize(image)
            sourceText = text
            sourceLanguage = TranslateLanguages.normalizedID(TextRecognizer.dominantLanguage(of: text))
        } catch {
            recognizeError = "识别失败：\(error.localizedDescription)"
        }
        isRecognizing = false
        if mode == .translate { startTranslation() }
    }

    private func loadTargetOptions() async {
        let supported = await LanguageAvailability().supportedLanguages
        var ids = TranslateLanguages.common
        for id in supported.compactMap(TranslateLanguages.normalizedID) where !ids.contains(id) { ids.append(id) }
        let rest = ids.dropFirst(TranslateLanguages.common.count)
            .sorted { TranslateLanguages.displayName($0).localizedStandardCompare(TranslateLanguages.displayName($1)) == .orderedAscending }
        targetOptions = TranslateLanguages.common + rest
        if !targetOptions.contains(target) { targetOptions.append(target) }
    }

    // MARK: 翻译

    func startTranslation() {
        guard !isRecognizing, hasText else { return }
        if mode != .translate {
            mode = .translate
            onModeChange?(.translate)
        }
        // 原文可能被编辑过，重新判断语言
        let source = TranslateLanguages.normalizedID(TextRecognizer.dominantLanguage(of: sourceText))
        sourceLanguage = source
        if !userPickedTarget { target = TranslateLanguages.defaultTarget(forSource: source) }
        translateError = nil
        if source == target {
            translatedText = ""
            translateError = "原文已经是\(TranslateLanguages.displayName(target))，请换一种目标语言"
            return
        }
        isTranslating = true
        let src = source.map { Locale.Language(identifier: $0) }
        let dst = Locale.Language(identifier: target)
        Task {
            if let src, await LanguageAvailability().status(from: src, to: dst) == .unsupported {
                isTranslating = false
                translateError = "系统不支持 \(TranslateLanguages.displayName(source!)) → \(TranslateLanguages.displayName(target)) 的翻译"
                return
            }
            // 源语言交给翻译框架自动检测：中英混排时整段判断出的语言不可靠，写死会把另一种语言的段落翻错
            if config == nil {
                config = TranslationSession.Configuration(source: nil, target: dst)
            } else {
                config?.target = dst
                config?.invalidate()
            }
        }
    }

    func translate(using session: TranslationSession) async {
        let text = sourceText
        let paragraphs = TextLayout.paragraphs(text).map(TextLayout.reflow).filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { isTranslating = false; return }
        let requests = paragraphs.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        do {
            let responses = try await session.translations(from: requests)
            let ordered = responses.sorted { Int($0.clientIdentifier ?? "") ?? 0 < Int($1.clientIdentifier ?? "") ?? 0 }
            translatedText = ordered.map(\.targetText).joined(separator: "\n\n")
            lastTranslatedSource = text
        } catch {
            translatedText = ""
            translateError = "翻译失败：\(error.localizedDescription)"
        }
        isTranslating = false
    }

    func setTarget(_ id: String) {
        guard id != target else { return }
        target = id
        userPickedTarget = true
        AppSettings.defaults.set(id, forKey: SettingsKey.translateTarget)
        startTranslation()
    }

    // MARK: 复制

    func copy(_ text: String, hint message: String) {
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hint = message
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { hint = nil }
        }
    }

    /// ⌘C 且没有选中文字时：翻译模式复制译文，识别模式复制全部识别结果
    func copyPrimary() {
        if mode == .translate, !translatedText.isEmpty {
            copy(translatedText, hint: "已复制译文")
        } else {
            copy(sourceText, hint: "已复制")
        }
    }
}

// MARK: - 视图

struct TextPanelView: View {
    @ObservedObject var model: TextPanelModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.mode == .recognize {
                header(title: "识别结果", trailing: model.sourceLanguage.map { "语言：\(TranslateLanguages.displayName($0))" })
                sourceEditor
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        header(title: "原文", trailing: model.sourceLanguage.map(TranslateLanguages.displayName))
                        sourceEditor
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("译文").font(.headline)
                            Spacer()
                            Picker("目标语言", selection: Binding(get: { model.target }, set: { model.setTarget($0) })) {
                                ForEach(model.targetOptions, id: \.self) { Text(TranslateLanguages.displayName($0)).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        .frame(height: 22)
                        translationEditor
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 220)
        .translationTask(model.config) { session in
            await model.translate(using: session)
        }
    }

    private func header(title: String, trailing: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(height: 22)
    }

    private var sourceEditor: some View {
        editor(text: $model.sourceText)
            .overlay {
                if model.isRecognizing {
                    ProgressView("正在识别…").controlSize(.small)
                } else if let err = model.recognizeError {
                    placeholder(err)
                } else if !model.hasText {
                    placeholder("未识别到文字")
                }
            }
    }

    private var translationEditor: some View {
        editor(text: $model.translatedText)
            .overlay {
                if model.isRecognizing || model.isTranslating {
                    ProgressView("正在翻译…").controlSize(.small)
                } else if let err = model.translateError {
                    placeholder(err)
                }
            }
    }

    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let hint = model.hint {
                Label(hint, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            Spacer()
            if model.mode == .recognize {
                Button("翻译") { model.startTranslation() }
                    .disabled(model.isRecognizing || !model.hasText)
                Button("复制") { model.copy(model.sourceText, hint: "已复制") }
                    .disabled(!model.hasText)
            } else {
                Button("重新翻译") { model.startTranslation() }
                    .disabled(!model.canRetranslate)
                Button("复制原文") { model.copy(model.sourceText, hint: "已复制原文") }
                    .disabled(!model.hasText)
                Button("复制译文") { model.copy(model.translatedText, hint: "已复制译文") }
                    .disabled(model.translatedText.isEmpty)
            }
            Button("关闭", action: onClose)
        }
    }
}

// MARK: - 窗口

/// 识别 / 翻译结果面板：Esc 或 ⌘W 关闭；没有选中文字时 ⌘C 复制全部
final class TextPanel: NSPanel {
    var onCopyAll: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let textView = firstResponder as? NSTextView
            if event.keyCode == 53, mods.isEmpty, textView?.hasMarkedText() != true {   // Esc（输入法组字时除外）
                performClose(nil)
                return
            }
            if mods == .command, chars == "w" {
                performClose(nil)
                return
            }
            if mods == .command, chars == "c", textView.map({ $0.selectedRange().length == 0 }) ?? true {
                onCopyAll?()
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class TextPanelController: NSObject, NSWindowDelegate {
    private static var openPanels: [TextPanelController] = []

    static let recognizeSize = NSSize(width: 440, height: 320)
    static let translateSize = NSSize(width: 760, height: 400)

    private let panel: TextPanel
    private let model: TextPanelModel

    /// anchor：选区在全局坐标中的位置，用于把面板放在选区附近
    static func show(image: CGImage, anchor: NSRect, translate: Bool) {
        let c = TextPanelController(image: image, anchor: anchor, translate: translate)
        openPanels.append(c)
        NSApp.activate(ignoringOtherApps: true)
        c.panel.makeKeyAndOrderFront(nil)
    }

    private init(image: CGImage, anchor: NSRect, translate: Bool) {
        model = TextPanelModel(image: image, translate: translate)
        let size = translate ? Self.translateSize : Self.recognizeSize
        panel = TextPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = translate ? "翻译" : "识别文字"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 240)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TextPanelView(model: model) { [weak self] in self?.panel.performClose(nil) })
        panel.onCopyAll = { [weak self] in self?.model.copyPrimary() }
        panel.setFrame(Self.frame(size: size, near: anchor), display: false)

        model.onModeChange = { [weak self] mode in
            guard let self, mode == .translate else { return }
            self.panel.title = "翻译"
            self.growToTranslateSize()
        }
    }

    private static func frame(size: NSSize, near anchor: NSRect) -> NSRect {
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12
        var y: CGFloat
        if anchor.minY - gap - size.height >= visible.minY {
            y = anchor.minY - gap - size.height          // 选区下方
        } else if anchor.maxY + gap + size.height <= visible.maxY {
            y = anchor.maxY + gap                        // 选区上方
        } else {
            y = visible.midY - size.height / 2           // 都放不下：屏幕中间
        }
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// 切到翻译模式时加宽，保持左上角不动并限制在屏幕内
    private func growToTranslateSize() {
        var f = panel.frame
        let top = f.maxY
        f.size.width = max(f.width, Self.translateSize.width)
        f.size.height = max(f.height, Self.translateSize.height)
        f.origin.y = top - f.height
        if let visible = panel.screen?.visibleFrame {
            f.origin.x = min(max(f.minX, visible.minX + 8), visible.maxX - f.width - 8)
            f.origin.y = min(max(f.minY, visible.minY + 8), visible.maxY - f.height - 8)
        }
        panel.setFrame(f, display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.openPanels.removeAll { $0 === self }
        // 没有其他需要焦点的窗口时把焦点还给之前的应用
        let others = NSApp.windows.contains {
            $0 !== panel && $0.isVisible && $0.canBecomeKey && $0.className != "NSStatusBarWindow"
                && !($0 is OverlayWindow) && !($0 is FloatingPanel) && !($0 is PinWindow)
        }
        if !others && !CaptureCoordinator.shared.isActive { NSApp.deactivate() }
    }
}
