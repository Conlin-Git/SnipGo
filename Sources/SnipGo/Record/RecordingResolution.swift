import Foundation

enum RecordingResolution: String, CaseIterable {
    case original, p2160, p1440, p1080, p720

    var title: String {
        switch self {
        case .original: return "原始分辨率"
        case .p2160: return "4K（2160p）"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    private var shortEdge: CGFloat? {
        switch self {
        case .original: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }

    func outputSize(for nativeSize: CGSize) -> CGSize {
        func evenPixels(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        let width = evenPixels(nativeSize.width.rounded())
        let height = evenPixels(nativeSize.height.rounded())
        var scale: CGFloat = 1
        if let shortEdge {
            let longEdge = shortEdge * 16 / 9
            scale = min(1, longEdge / max(width, height), shortEdge / min(width, height))
        }
        // 编码器需要偶数像素。小选区保留原尺寸，竖屏随选区旋转上限。
        return CGSize(width: max(2, (width * scale / 2).rounded() * 2),
                      height: max(2, (height * scale / 2).rounded() * 2))
    }
}
