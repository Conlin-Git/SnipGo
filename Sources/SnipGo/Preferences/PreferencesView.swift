import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @AppStorage(SettingsKey.playSound) private var playSound = true
    @AppStorage(SettingsKey.imageFormat) private var imageFormat = "png"
    @AppStorage(SettingsKey.recordSystemAudio) private var recordSystemAudio = false
    @AppStorage(SettingsKey.recordMicrophone) private var recordMicrophone = false
    @AppStorage(SettingsKey.recordShowCursor) private var recordShowCursor = true
    @AppStorage(SettingsKey.filePrefix) private var filePrefix = "SnipGo_"
    @AppStorage(SettingsKey.saveDirectory) private var saveDirectory = AppSettings.defaultSaveDirectory
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    private var previewName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(filePrefix)\(f.string(from: Date())).\(imageFormat)"
    }

    var body: some View {
        // 参考样式：右对齐的标签列 + 左对齐的内容列，分组之间留出较大间距
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 26) {
            row("启动:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("开机自动运行 SnipGo", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                    if let launchError {
                        Text(launchError).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            row("截图:") {
                Toggle("截图完成时播放提示音", isOn: $playSound)
            }

            row("截图存储格式:") {
                Picker("", selection: $imageFormat) {
                    Text("jpg").tag("jpg")
                    Text("png").tag("png")
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }

            row("录屏:") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("录制系统声音", isOn: $recordSystemAudio)
                    Toggle("录制麦克风", isOn: $recordMicrophone)
                    Toggle("显示鼠标指针", isOn: $recordShowCursor)
                    Text("视频格式：mp4（H.264）").font(.callout).foregroundStyle(.secondary)
                }
            }

            row("截图快捷键:") {
                ShortcutRecorderView(action: .capture).frame(width: 200, height: 28)
            }

            row("录屏快捷键:") {
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRecorderView(action: .record).frame(width: 200, height: 28)
                    Text("录制中再按一次即停止").font(.callout).foregroundStyle(.secondary)
                }
            }

            row("文件名前缀:") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: $filePrefix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Text("预览：\(previewName)").font(.callout).foregroundStyle(.secondary)
                }
            }

            row("截图保存位置:") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(saveDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320, alignment: .leading)
                    HStack(spacing: 10) {
                        Button("修改") { chooseDirectory() }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: saveDirectory, isDirectory: true))
                        }
                    }
                    .controlSize(.large)
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 14))
        .padding(.horizontal, 60)
        .padding(.top, 36)
        .padding(.bottom, 40)
        .frame(width: 640, alignment: .topLeading)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 130, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content()
                .gridColumnAlignment(.leading)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        // 参考样式：窗口顶部工具栏式标签页（通用 / 关于）
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        tabs.addTabViewItem(Self.tab(PreferencesView(), label: "通用", symbol: "gearshape"))
        tabs.addTabViewItem(Self.tab(AboutView(), label: "关于", symbol: "info.circle"))

        let window = NSWindow(contentViewController: tabs)
        window.title = "偏好设置"
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    private static func tab<V: View>(_ view: V, label: String, symbol: String) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = label
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
