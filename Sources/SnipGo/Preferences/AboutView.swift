import AppKit
import SwiftUI

/// 应用与作者信息
enum AppInfo {
    static let name = "SnipGo"
    static let repositoryURL = URL(string: "https://github.com/Conlin-Git/SnipGo")!
    static let issuesURL = URL(string: "https://github.com/Conlin-Git/SnipGo/issues")!
    static let author = "Conlin"
    static let authorGitHub = "Conlin-Git"
    static let authorURL = URL(string: "https://github.com/Conlin-Git")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    static var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) \(author)"
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .padding(.bottom, 10)

            Text(AppInfo.name)
                .font(.system(size: 26, weight: .semibold))
            Text("版本 \(AppInfo.version)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("macOS 菜单栏截图工具：截图 · 圈图标注 · 马赛克 · 滚动长图 · 钉图 · 录视频")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
                infoRow("作者:") {
                    Text(AppInfo.author)
                }
                infoRow("GitHub:") {
                    Link("@\(AppInfo.authorGitHub)", destination: AppInfo.authorURL)
                }
                infoRow("项目地址:") {
                    HStack(spacing: 8) {
                        Link(AppInfo.repositoryURL.absoluteString, destination: AppInfo.repositoryURL)
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(AppInfo.repositoryURL.absoluteString, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制项目地址")
                    }
                }
                infoRow("问题反馈:") {
                    Link("GitHub Issues", destination: AppInfo.issuesURL)
                }
            }
            .font(.system(size: 14))
            .padding(.top, 28)

            Text(AppInfo.copyright)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 30)
        }
        .padding(.horizontal, 60)
        .padding(.top, 32)
        .padding(.bottom, 32)
        .frame(width: 640)
    }

    @ViewBuilder
    private func infoRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 130, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content()
                .gridColumnAlignment(.leading)
        }
    }
}
