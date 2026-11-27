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
    @Published private(set) var hint: String?

    private var userPickedTarget = false
    private var hintTask: Task<Void, Never>?

    init(image: CGImage, translate: Bool) {
        mode = translate ? .translate : .recognize
        target = TranslateLanguages.defaultTarget(forSource: nil)
        Task { await recognize(image) }
        Task { await loadTargetOptions() }
    }

    var hasText: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        mode = .translate
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
        } catch {
            translatedText = ""
            translateError = "翻译失败：\(error.localizedDescription)"
        }
        isTranslating = false
    }

    /// 切回识别结果（复用已识别的文字，不重新识别）
    func showRecognition() {
        mode = .recognize
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

/// 内嵌在截图遮罩里、贴在选区旁边的结果卡片（参考样式：白色圆角卡片，标题 + 关闭，正文，底部蓝色「复制」）
struct TextCardView: View {
    @ObservedObject var model: TextPanelModel
    let onClose: () -> Void
    /// 正在选择目标语言：卡片内显示语言列表（遮罩窗口层级很高，系统弹出菜单可能被挡住，所以不用 Picker）
    @State private var pickingLanguage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if pickingLanguage {
                    languageList
                } else if model.mode == .recognize {
                    sourceEditor
                } else {
                    translationEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 16))
        .frame(width: TextResultCard.size.width, height: TextResultCard.size.height)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: model.mode) { pickingLanguage = false }
        .translationTask(model.config) { session in
            await model.translate(using: session)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.mode == .recognize {
                Text("识别结果").font(.system(size: 16, weight: .semibold))
            } else {
                Text("翻译为").font(.system(size: 16)).foregroundStyle(.secondary)
                Button { pickingLanguage.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(TranslateLanguages.displayName(model.target)).font(.system(size: 16, weight: .semibold))
                        Image(systemName: pickingLanguage ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
                .padding(.leading, -6)
                .help("切换目标语言")
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("关闭 Esc")
        }
        .frame(height: 24)
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
                } else if let err = model.recognizeError ?? model.translateError {
                    placeholder(err)
                } else if !model.hasText {
                    placeholder("未识别到文字")
                }
            }
    }

    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(.leading, -5)   // 抵消 NSTextView 的内边距，让文字与标题左对齐
    }

    private var languageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.targetOptions, id: \.self) { id in
                    Button {
                        pickingLanguage = false
                        model.setTarget(id)
                    } label: {
                        HStack {
                            Text(TranslateLanguages.displayName(id)).font(.system(size: 14))
                            Spacer()
                            if id == model.target {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(id == model.target ? Color.accentColor.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                        .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
        let canCopy = model.mode == .recognize ? model.hasText : !model.translatedText.isEmpty
        return HStack {
            if let hint = model.hint {
                Label(hint, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            } else {
                Text(model.mode == .recognize ? "系统离线识别" : "系统离线翻译").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { model.copyPrimary() } label: {
                CopyButtonLabel(enabled: canCopy)
            }
            .buttonStyle(.plain)
            .disabled(!canCopy)
            .opacity(canCopy ? 1 : 0.4)
            .help(model.mode == .recognize ? "复制识别结果" : "复制译文")
        }
    }
}

// MARK: - 容器

/// 截图遮罩中的结果卡片容器：作为 SelectionView 的子视图显示，不单独弹出窗口
@MainActor
final class TextResultCard: NSView {
    static let size = NSSize(width: 320, height: 360)

    let model: TextPanelModel
    /// 卡片对应的选区（全局坐标）；选区变化后结果失效，卡片随之关闭
    let anchor: CGRect
    var onClose: (() -> Void)?

    init(image: CGImage, anchor: CGRect, translate: Bool) {
        model = TextPanelModel(image: image, translate: translate)
        self.anchor = anchor
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        let host = NSHostingView(rootView: TextCardView(model: model) { [weak self] in self?.onClose?() })
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 键盘焦点是否在卡片内（正在编辑 / 选择文字）
    var containsFirstResponder: Bool {
        guard let v = window?.firstResponder as? NSView else { return false }
        return v.isDescendant(of: self)
    }

    /// 卡片内的文本框处于输入法组字状态
    var hasMarkedText: Bool {
        (window?.firstResponder as? NSTextView).map { $0.isDescendant(of: self) && $0.hasMarkedText() } ?? false
    }

    /// ⌘C：有选中文字时复制选中部分，否则复制当前主要内容（识别结果 / 译文）
    func copyText() {
        if let tv = window?.firstResponder as? NSTextView, tv.isDescendant(of: self), tv.selectedRange().length > 0 {
            tv.copy(nil)
        } else {
            model.copyPrimary()
        }
    }
}

// MARK: - 悬停样式

/// 卡片内按钮的悬停样式：浅色背景 + 手形光标
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

private extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

/// 蓝色「复制」按钮：悬停时加深并显示手形光标
private struct CopyButtonLabel: View {
    let enabled: Bool
    @State private var hovering = false

    var body: some View {
        Text("复制")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 32)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().fill(Color.black.opacity(enabled && hovering ? 0.15 : 0)))
            .contentShape(Capsule())
            .onHover { inside in
                hovering = inside
                (inside && enabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}
