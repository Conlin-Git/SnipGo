import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 最近五张完成的截图，只在本次运行可见。拖出时才生成临时 PNG。
@MainActor
final class RecentCaptures: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = RecentCaptures()

    private final class Entry {
        let image: CGImage
        let size: NSSize
        let time = Date()
        let id = UUID()
        var exportedURL: URL?

        init(_ image: CGImage, size: NSSize) {
            self.image = image
            self.size = size
        }

        deinit {
            if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        }
    }

    private var entries: [Entry] = []
    private let table = NSTableView()
    private var panel: NSPanel?
    private var thumbnail: RecentThumbnailPanel?
    private let status = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let clearButton = NSButton()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnipGo-" + UUID().uuidString, isDirectory: true)

    func add(_ image: CGImage, size: NSSize) {
        let entry = Entry(image, size: size)
        entries.insert(entry, at: 0)
        if entries.count > 5 { entries.removeLast() }
        refresh()
        dismissThumbnail()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let thumbnail = RecentThumbnailPanel(image: NSImage(cgImage: image, size: size), screen: screen,
            export: { [weak self] in self?.exportFile(entry) },
            open: { [weak self] in self?.show() })
        self.thumbnail = thumbnail
        thumbnail.present()
    }

    func dismissThumbnail() {
        thumbnail?.orderOut(nil)
        thumbnail = nil
    }

    func show() {
        dismissThumbnail()
        if panel == nil { buildPanel() }
        refresh()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPanel() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 355),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "最近截图"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        let column = NSTableColumn(identifier: .init("captures"))
        column.width = 365
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 49
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        copyButton.title = "复制选中"
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        clearButton.title = "清空"
        clearButton.target = self
        clearButton.action = #selector(clear)
        let actions = NSStackView(views: [copyButton, clearButton])
        let stack = NSStackView(views: [status, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 253).isActive = true
        panel = window
    }

    private func refresh() {
        guard panel != nil else { return }
        table.reloadData()
        status.stringValue = entries.isEmpty ? "完成截图后会显示在这里" : "拖到附件区或 Finder，按住 ⌘ 可多选"
        clearButton.isEnabled = !entries.isEmpty
        copyButton.isEnabled = table.numberOfSelectedRows == 1
    }

    @objc func clear() {
        dismissThumbnail()
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
        refresh()
    }

    @objc private func copySelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        ImageOutput.copyToPasteboard(entry.image, pointSize: entry.size)
        status.stringValue = "已复制截图"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        copyButton.isEnabled = table.numberOfSelectedRows == 1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let preview = NSImageView(image: NSImage(cgImage: entry.image, size: entry.size))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 64).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let time = entry.time.formatted(date: .omitted, time: .standard)
        let label = NSTextField(labelWithString: "\(time)     \(entry.image.width) × \(entry.image.height)")
        let stack = NSStackView(views: [preview, label])
        stack.distribution = .gravityAreas
        stack.spacing = 12
        return stack
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        exportFile(entries[row])
    }

    private func exportFile(_ entry: Entry) -> NSURL? {
        if let url = entry.exportedURL { return url as NSURL }
        let url = directory.appendingPathComponent("SnipGo-\(entry.id.uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(dest, entry.image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            entry.exportedURL = url
            return url as NSURL
        } catch {
            try? FileManager.default.removeItem(at: url)
            status.stringValue = "导出失败，可重新拖动"
            return nil
        }
    }
}
