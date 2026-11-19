import AppKit

/// 状态栏右键弹出的菜单。新版 macOS 自带菜单是很透的“液态玻璃”，文字容易被背景干扰，
/// 所以这里自绘一个小面板，做法和传统的 macOS 菜单一致：系统 `.menu` 模糊材质（半透明、
/// 会随明暗模式和壁纸变化）+ 一圈很淡的内描边，不再叠自己的底色和硬边框。
/// 用到时才创建，关掉就释放。
final class StatusMenu {
    struct Entry {
        let title: String
        let action: () -> Void
    }

    private static let width: CGFloat = 168
    private static let rowHeight: CGFloat = 28
    private static let padding: CGFloat = 5
    fileprivate static let cornerRadius: CGFloat = 10

    fileprivate static let hover = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
    }
    fileprivate static let text = NSColor.labelColor

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isShown: Bool { panel != nil }

    /// 在状态栏按钮下方弹出。
    func show(entries: [Entry], below button: NSStatusBarButton) {
        close()
        guard let window = button.window else { return }

        let height = CGFloat(entries.count) * Self.rowHeight + Self.padding * 2
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        content.material = .menu
        content.blendingMode = .behindWindow
        content.state = .active
        content.maskImage = Self.maskImage()

        for (index, entry) in entries.enumerated() {
            let y = height - Self.padding - CGFloat(index + 1) * Self.rowHeight
            let row = MenuRow(frame: NSRect(x: Self.padding, y: y, width: Self.width - Self.padding * 2,
                                            height: Self.rowHeight),
                              title: entry.title, hover: Self.hover) { [weak self] in
                self?.close()
                entry.action()
            }
            content.addSubview(row)
        }
        content.addSubview(MenuBorder(frame: content.bounds))

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = content

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = buttonFrame.midX - Self.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - Self.width - 6)
        let y = buttonFrame.minY - height - 4
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        self.panel = panel

        // 点到面板外面、或按 Esc 就收起来。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode != 53 { return }
            self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // 点在状态栏图标上时不在这里处理，由图标自己的点击逻辑决定是关掉还是重新打开。
            if let self, let panel = self.panel, event.window !== panel, event.window !== window { self.close() }
            return event
        }
    }

    func close() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// 可拉伸的圆角遮罩：模糊材质和窗口阴影都按这个形状裁切。
    private static func maskImage() -> NSImage {
        let r = cornerRadius
        let image = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// 贴着边缘的一圈很淡的描边（不拦截鼠标），和系统菜单的质感接近。
private final class MenuBorder: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.14)).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: StatusMenu.cornerRadius, yRadius: StatusMenu.cornerRadius)
        path.lineWidth = Theme.hairline
        path.stroke()
    }
}

/// 一行菜单项：鼠标移上去底色变深，抬起时执行。
private final class MenuRow: NSView {
    private let label: NSTextField
    private let hoverColor: NSColor
    private let onClick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(frame: NSRect, title: String, hover: NSColor, onClick: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        hoverColor = hover
        self.onClick = onClick
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = StatusMenu.text
        label.frame = NSRect(x: 10, y: (frame.height - 17) / 2, width: frame.width - 20, height: 17)
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        hoverColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
