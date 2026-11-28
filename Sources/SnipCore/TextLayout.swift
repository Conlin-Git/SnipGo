import Foundation

/// OCR 识别片段：文字 + 像素坐标包围框（左上角为原点，y 向下）
public struct TextFragment: Equatable, Sendable {
    public var text: String
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(text: String, minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.text = text
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var midY: Double { (minY + maxY) / 2 }
}

/// 把 OCR 片段排成可读文本：按栏 → 按行 → 按段落
public enum TextLayout {

    /// 行内用空格分隔、行之间换行、段落之间空一行；多栏时逐栏输出
    public static func compose(_ fragments: [TextFragment]) -> String {
        let items = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.width > 0 && $0.height > 0 }
        guard !items.isEmpty else { return "" }
        return splitColumns(items)
            .map { composeColumn($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 把一个段落内的多行合并成一行（用于翻译）：中日韩文字之间直接相连，其他用空格；行尾连字符去掉
    public static func reflow(_ paragraph: String) -> String {
        let lines = paragraph.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var result = lines.first else { return "" }
        for line in lines.dropFirst() {
            guard let last = result.last, let first = line.first else { continue }
            if last == "-", result.count >= 2, result[result.index(before: result.index(before: result.endIndex))].isLetter, first.isLowercase {
                result.removeLast()          // 英文断词：exam- ple → example
                result += line
            } else if isCJK(last) || isCJK(first) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    /// 按空行拆分段落
    public static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")); current.removeAll() }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// 规则表格：根据横跨各行的空白带确定列，再把每行的文字放回相应位置。
    public static func tableRows(_ fragments: [TextFragment]) -> [[String]] {
        let items = fragments.filter { $0.width > 0 && $0.height > 0 && !$0.text.isEmpty }
        guard !items.isEmpty else { return [] }
        let gap = max(2, median(items.map(\.height)) * 0.5)
        var edges: [Double] = []
        for item in items.sorted(by: { $0.minX < $1.minX }) {
            if let end = edges.last, item.minX - end <= gap {
                edges[edges.count - 1] = max(end, item.maxX)
            } else {
                edges.append(item.maxX)
            }
        }
        return groupLines(items).map { line in
            var columns = Array(repeating: [TextFragment](), count: edges.count)
            var index = 0
            for fragment in line {
                while index + 1 < edges.count && fragment.minX > edges[index] { index += 1 }
                columns[index].append(fragment)
            }
            return columns.map { $0.isEmpty ? "" : joinLine($0) }
        }
    }

    public static func tabSeparated(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ")
                .components(separatedBy: .newlines).joined(separator: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    // MARK: - 分栏

    /// 找出所有片段都不覆盖的竖向空白带作为栏间距；只有每栏都像正文（行数够、行够宽）时才分栏，避免把表格拆散
    static func splitColumns(_ items: [TextFragment]) -> [[TextFragment]] {
        guard items.count >= 6 else { return [items] }
        let minX = items.map(\.minX).min()!, maxX = items.map(\.maxX).max()!
        let totalWidth = maxX - minX
        guard totalWidth > 0 else { return [items] }

        // 合并横向覆盖区间，区间之间的空隙就是候选栏间距
        let spans = items.map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for s in spans {
            if let last = merged.last, s.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, s.1) } else { merged.append(s) }
        }
        let medianHeight = median(items.map(\.height))
        let minGap = max(totalWidth * 0.03, medianHeight * 1.5)
        var columns: [(Double, Double)] = []
        var start = merged[0].0
        for i in 1..<merged.count where merged[i].0 - merged[i - 1].1 >= minGap {
            columns.append((start, merged[i - 1].1))
            start = merged[i].0
        }
        columns.append((start, merged[merged.count - 1].1))
        guard columns.count > 1 else { return [items] }

        let groups = columns.map { col in items.filter { $0.minX >= col.0 && $0.maxX <= col.1 } }
        for (col, group) in zip(columns, groups) {
            let lines = groupLines(group)
            let colWidth = col.1 - col.0
            let avgFill = lines.map { line in (line.last!.maxX - line.first!.minX) / colWidth }.reduce(0, +) / Double(max(lines.count, 1))
            if lines.count < 3 || avgFill < 0.6 { return [items] }
        }
        return groups
    }

    // MARK: - 行与段落

    static func composeColumn(_ items: [TextFragment]) -> String {
        let lines = groupLines(items)
        guard !lines.isEmpty else { return "" }
        let texts = lines.map(joinLine)
        let boxes = lines.map { line in (minY: line.map(\.minY).min()!, maxY: line.map(\.maxY).max()!) }
        let lineHeight = median(boxes.map { $0.maxY - $0.minY })
        let gaps = zip(boxes, boxes.dropFirst()).map { $1.minY - $0.maxY }
        // 段落间距：明显大于普通行距（普通行距取中位数）
        let normalGap = gaps.isEmpty ? 0 : max(median(gaps), 0)
        let threshold = max(lineHeight * 0.8, normalGap + lineHeight * 0.5)

        var out = texts[0]
        for i in 1..<texts.count {
            out += gaps[i - 1] > threshold ? "\n\n" : "\n"
            out += texts[i]
        }
        return out
    }

    /// 纵向重叠超过较矮者高度一半的片段视为同一行；行内按 x 排序，行按 y 排序
    static func groupLines(_ items: [TextFragment]) -> [[TextFragment]] {
        var lines: [[TextFragment]] = []
        for f in items.sorted(by: { $0.midY < $1.midY }) {
            if let i = lines.firstIndex(where: { line in
                let top = line.map(\.minY).min()!, bottom = line.map(\.maxY).max()!
                let overlap = min(bottom, f.maxY) - max(top, f.minY)
                return overlap > 0.5 * min(bottom - top, f.height)
            }) {
                lines[i].append(f)
            } else {
                lines.append([f])
            }
        }
        return lines
            .map { $0.sorted { $0.minX < $1.minX } }
            .sorted { $0.map(\.midY).min()! < $1.map(\.midY).min()! }
    }

    static func joinLine(_ line: [TextFragment]) -> String {
        var out = line[0].text.trimmingCharacters(in: .whitespaces)
        for (prev, cur) in zip(line, line.dropFirst()) {
            let text = cur.text.trimmingCharacters(in: .whitespaces)
            guard let last = out.last, let first = text.first else { out += text; continue }
            let charWidth = prev.width / Double(max(prev.text.count, 1))
            let gap = cur.minX - prev.maxX
            if isCJK(last) && isCJK(first) && gap < charWidth * 1.5 {
                out += text                 // 同一句中文被拆开，直接相连
            } else {
                out += " " + text
            }
        }
        return out
    }

    // MARK: - 工具

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3000...0x303F,   // 中日韩标点
             0x3040...0x30FF,   // 平假名、片假名
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, // 汉字
             0xAC00...0xD7AF,   // 韩文
             0xFF00...0xFFEF:   // 全角符号
            return true
        default:
            return false
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
