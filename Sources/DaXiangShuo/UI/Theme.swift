import AppKit
import SwiftUI

/// 主界面的配色和尺寸。浅色取自 Cursor 设置页，深色为对应的暗色版本。
/// 全部文字统一 13pt 常规字重（和侧栏一致），输入框、按钮统一 28pt 高。
enum Theme {
    static let sidebar = dynamic(0xF1F0EF, 0x1C1C1C)
    static let sidebarSelection = dynamic(0xE4E3E1, 0x2D2D2D)
    static let sidebarHover = dynamic(0xEAE9E7, 0x262626)
    static let sidebarBorder = dynamic(0xE6E5E3, 0x2A2A2A)
    static let background = dynamic(0xF7F7F7, 0x161616)
    static let card = dynamic(0xEFEFEF, 0x212121)
    static let divider = dynamic(0xE5E5E5, 0x2B2B2B)
    static let control = dynamic(0xFFFFFF, 0x2A2A2A)
    static let controlHover = dynamic(0xFAFAFA, 0x303030)
    static let controlPressed = dynamic(0xF0F0F0, 0x363636)
    static let border = dynamic(0xDADADA, 0x3A3A3A)
    static let text = dynamic(0x1F1F1F, 0xE8E8E8)
    static let secondary = dynamic(0x707070, 0x9C9C9C)
    static let tertiary = dynamic(0xA0A0A0, 0x6C6C6C)
    static let accent = dynamic(0x1F7A4F, 0x2F9E68)
    static let warning = dynamic(0xB36B00, 0xD99A3E)
    /// 两个渠道的品牌色，用在渠道卡片和图标上。
    static let volcengine = dynamic(0xF0532B, 0xFF7A4D)
    static let deepseek = dynamic(0x3F5BF6, 0x7C90FF)

    /// 侧栏左下角的升级按钮：很浅的蓝底、蓝色描边、蓝色小字。
    static let updateFill = dynamic(0xEAF1FF, 0x17233A)
    static let updateBorder = dynamic(0x9DB9F7, 0x3C5E9E)
    static let updateText = dynamic(0x2F55C8, 0x8FB0FF)
    static let danger = dynamic(0xC0392B, 0xE0685B)

    static let font = Font.system(size: 13, weight: .regular)
    /// 主窗口固定尺寸：高度 500，宽度按黄金分割（宽 = 高 × 1.618）取整为 809。
    static let windowSize = CGSize(width: (500.0 * (1 + 5.0.squareRoot()) / 2).rounded(), height: 500)
    /// API Key 和模型名称输入框的统一宽度。
    static let keyFieldWidth: CGFloat = 200
    static let controlHeight: CGFloat = 28
    /// 控件（输入框、按钮）圆角。8pt 在 1x 屏上圆弧有 8 个像素，比 6pt 明显更顺。
    static let radius: CGFloat = 8
    /// 卡片圆角。
    static let cardRadius: CGFloat = 10
    /// 控件底下的一层极淡阴影：1x 屏上圆角的锯齿会被它糊掉，看起来更顺。
    static let controlShadow = Color.black.opacity(0.06)

    /// 一条设备像素的线宽：2x 屏上是 0.5pt，1x 屏上是 1pt。
    /// 固定写 0.5 在非视网膜屏上只有半个像素，描边会被抹成灰色、圆角也会断断续续。
    static var hairline: CGFloat {
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        return 1 / scale
    }

    /// 控件（输入框、按钮）的圆角形状，统一从这里取，避免各处半径/曲线不一致。
    static func controlShape(_ radius: CGFloat = Theme.radius) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .circular)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: 页面骨架

/// 右侧内容页：居中的定宽内容列。
/// 不再画页面标题：左边侧栏选中哪一项已经写着了，右边再来一行同名标题是重复。
/// `scrolls: true` 时整页可滚动，顶部有渐隐，滚动时内容自然淡出而不是压在标题栏上。
/// 设置项会随版本增加（窗口高度固定 500），所以设置页一律滚动；只有词典页例外，
/// 它的列表在那块固定高度里自己滚，上面的添加区要始终可见。
struct Page<Content: View>: View {
    var scrolls = false
    @ViewBuilder var content: Content

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 32)
        // 上面只留出「更新胶囊 / 红绿灯」那一条：内容整体往上提，别空着一条。
        .padding(.top, 16)
        .padding(.bottom, scrolls ? 48 : 24)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        if scrolls {
            ScrollView { column }
                .overlay(alignment: .top) { TopFade() }
        } else {
            column.frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct TopFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Theme.background, location: 0),
            .init(color: Theme.background, location: 0.45),
            .init(color: Theme.background.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
            .frame(height: 44)
            .allowsHitTesting(false)
    }
}

/// 区域标题，可以带一个说明图标。
struct SectionTitle<Trailing: View>: View {
    let text: String
    var info: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(Theme.secondary)
            if let info { InfoTip(text: info) }
            Spacer()
            trailing
        }
        .font(Theme.font)
        .padding(.leading, 2)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ text: String, info: String? = nil) {
        self.init(text: text, info: info) { EmptyView() }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 14)
    }
}

/// 卡片里的一行：左边名称（可带说明图标），右边控件。行高统一。
struct Row<Trailing: View>: View {
    let title: String
    var info: String?
    /// 标题右侧的「点击获取」链接，点击后用浏览器打开。
    var link: URL?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(Theme.text)
                if let info { InfoTip(text: info) }
                if let link { ConfigLink(url: link) }
            }
            .layoutPriority(1)
            Spacer(minLength: 16)
            trailing
        }
        .font(Theme.font)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

extension Row where Trailing == EmptyView {
    init(title: String, info: String? = nil) {
        self.init(title: title, info: info, link: nil) { EmptyView() }
    }
}

/// 「点击获取」文字链接。
struct ConfigLink: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Text("点击获取")
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.accent)
            .underline(hovering)
            .padding(.leading, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { NSWorkspace.shared.open(url) }
    }
}

/// 名称后面的小「i」图标：鼠标停留或点击后弹出说明。
struct InfoTip: View {
    let text: String
    @State private var shown = false
    @State private var hovering = false
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12, weight: .light))
            .foregroundStyle(hovering || shown ? Theme.secondary : Theme.tertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { shown.toggle() }
            .onHover { inside in
                hovering = inside
                hoverWork?.cancel()
                guard inside else { return }
                let work = DispatchWorkItem { shown = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(Theme.font)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(14)
            }
    }
}

/// 小圆点 + 文字的状态标记。
struct StatusBadge: View {
    let text: String
    let ok: Bool
    var neutral = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(neutral ? Theme.tertiary : (ok ? Theme.accent : Theme.warning))
                .frame(width: 6, height: 6)
            Text(text).font(Theme.font).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: 控件

/// 白底细边框的按钮，高 28pt。
struct SoftButtonStyle: ButtonStyle {
    var role: ButtonRole?

    func makeBody(configuration: Configuration) -> some View {
        SoftButton(configuration: configuration, destructive: role == .destructive)
    }

    private struct SoftButton: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.font)
                .foregroundStyle(destructive ? Theme.danger : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: Theme.controlHeight)
                .background(Theme.controlShape()
                    .fill(configuration.isPressed ? Theme.controlPressed : (hovering ? Theme.controlHover : Theme.control))
                    .shadow(color: Theme.controlShadow, radius: 1.2, y: 0.5))
                .overlay(Theme.controlShape()
                    .strokeBorder(Theme.border, lineWidth: Theme.hairline))
                .shadow(color: .black.opacity(0.04), radius: 0.5, y: 0.5)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softDestructive: SoftButtonStyle { SoftButtonStyle(role: .destructive) }
}

/// 只有图标的按钮，28pt 见方，悬停时出现浅灰底。
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(hovering ? Theme.sidebarSelection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 灰色的「清空」文字按钮，统一放在输入框或按钮的左侧。
struct ClearButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("清空")
                .font(Theme.font)
                .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                .padding(.horizontal, 6)
                .frame(height: Theme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.font)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: Theme.controlHeight)
            .background(Theme.controlShape().fill(Theme.control)
                .shadow(color: Theme.controlShadow, radius: 1.2, y: 0.5))
            .overlay(Theme.controlShape().strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}

struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(Theme.accent)
    }
}

/// 下拉选择：外观和按钮一致，点开是系统原生菜单。
struct SelectMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .buttonStyle(.soft)
        .fixedSize()
    }

    private func showMenu() {
        let menu = NSMenu()
        let target = MenuTarget()
        for (value, title) in options {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.state = value == selection ? .on : .off
            item.representedObject = MenuTarget.Box { selection = value }
            menu.addItem(item)
        }
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

private final class MenuTarget: NSObject {
    final class Box {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    @objc func pick(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.action()
    }
}

/// 灰底两段式切换，用来代替系统蓝色的分段控件。
struct SegmentedTabs<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(Theme.font)
                        .foregroundStyle(selection == value ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: Theme.controlHeight - 4)
                        .background(RoundedRectangle(cornerRadius: Theme.radius - 1, style: .circular)
                            .fill(selection == value ? Theme.control : .clear)
                            .shadow(color: .black.opacity(selection == value ? 0.06 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 1, style: .circular).fill(Theme.card))
    }
}
