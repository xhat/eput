import SwiftUI

/// 侧栏左下角那颗小小的「升级」按钮：很浅的蓝底、蓝色描边、蓝色小字，前面一个很小的图标。
/// 只有发现新版本时才出现——出现时它会顶掉那格原本的 GitHub 图标和版本号。
struct UpdateButton: View {
    let updates: UpdateService

    @State private var hovering = false

    var body: some View {
        switch updates.state {
        case .ready:
            Button {
                Task { await updates.install() }
            } label: {
                label("升级", icon: "arrow.up.circle.fill", active: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        case .downloading:
            label("下载中", icon: "arrow.down.circle", active: false)
                .help("新版本正在后台下载")
                .allowsHitTesting(false)
        case .installing:
            label("安装中", icon: "gearshape.2.fill", active: false)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private func label(_ text: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.updateText)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.updateFill.opacity(hovering && active ? 1 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.updateBorder, lineWidth: 1)
        )
        .opacity(active ? 1 : 0.7)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// 鼠标悬停说明：版本号 + 这次更新做了什么。
    private var help: String {
        let version = updates.release?.version ?? ""
        let note = updates.release?.notes
        return note.map { "点击安装大象说 \(version) 并重启\n\($0)" } ?? "点击安装大象说 \(version) 并重启"
    }
}
