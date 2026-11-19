import AppKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case general, models, phrases, statistics, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用设置"
        case .models: "模型设置"
        case .statistics: "统计信息"
        case .phrases: "词典设置"
        case .history: "历史记录"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .statistics: "chart.bar"
        case .phrases: "book.closed"
        case .history: "clock"
        }
    }
}

@Observable
final class Router {
    var section: MainSection? = .general
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let phrases = PhraseStore.shared
    private let router = Router()
    private var dictation: DictationController!
    private let updates = UpdateService()
    private var statusBar: StatusBarController!
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        dictation = DictationController(settings: settings, history: history, phrases: phrases)

        statusBar = StatusBarController()
        statusBar.onOpenMain = { [weak self] in self?.showMainWindow() }
        statusBar.onRestoreRaw = { [weak self] in self?.dictation.restoreLastRaw() }
        statusBar.canRestoreRaw = { [weak self] in self?.dictation.hasRawToRestore ?? false }
        dictation.onStateChange = { [weak self] state in self?.statusBar.setState(state) }

        Permissions.requestMicrophoneIfNeeded()
        let prompted = Permissions.promptAccessibilityIfNeeded()
        dictation.start()
        updates.start()
        LaunchReporter.start(settings: settings)

        // 没有可用的输入设备时不弹窗，等界面出来了再用胶囊给一次安静的提示。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.dictation.notifyMissingInputIfNeeded()
        }

        // 系统提示只弹一次。之后再没授权就安静地说一句，别每次都弹窗。
        if !prompted, !Permissions.accessibilityGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dictation.notifyAccessibilityMissing()
            }
        }

        // 调试用：DAXIANGSHUO_DEBUG_WINDOW=1 时启动就打开主界面，方便截图和排查更新胶囊。
        if ProcessInfo.processInfo.environment["DAXIANGSHUO_DEBUG_WINDOW"] == "1" {
            showMainWindow()
        }

        // 配置齐全时安静地待在状态栏；有缺项才主动打开主界面，并直接定位到缺项所在的页面。
        if let missing = settings.firstMissingSection {
            showMainWindow(section: missing)
        }
    }

    /// 标准关于面板，加上官网和 GitHub 链接。
    @objc private func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSMutableAttributedString()
        for (index, (title, url)) in [("官网 eput.ruoxie.com", AppLinks.website),
                                      ("GitHub xhat/eput", AppLinks.github)].enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "\n")) }
            credits.append(NSAttributedString(string: title, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style]))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// 没有主菜单时 ⌘V、⌘C 等快捷键在输入框里不起作用，所以必须有「编辑」菜单。
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于大象说", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "通用设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏大象说", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出大象说", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "大象说")

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "编辑")

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "窗口")
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc private func openSettings() {
        showMainWindow(section: .general)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.shutdown()
    }

    func showMainWindow(section: MainSection? = nil) {
        if let section { router.section = section }
        // 每打开一次主界面查一次更新（10 分钟内查过就跳过）。
        updates.checkOnWindowOpen()
        if mainWindow == nil {
            let root = MainView(router: router, settings: settings, history: history,
                                phrases: phrases, dictation: dictation, updates: updates)
            // 窗口尺寸固定，不可拖拽缩放：高 500，宽按黄金分割取 809。
            let size = Theme.windowSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "大象说"
            // 标题栏不显示文字，右侧内容滚到顶部时只会在渐隐区里淡出，不会和标题重叠。
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            window.setContentSize(size)
            window.contentMinSize = size
            window.contentMaxSize = size
            window.delegate = self
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// 关闭主界面时连同整个 SwiftUI 视图树一起释放，平时只留状态栏图标和听写所需的最小部分。
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.mainWindow, !window.isVisible else { return }
            window.contentView = nil
            window.delegate = nil
            self.mainWindow = nil
            self.history.unloadItems()
            UsageStore.shared.unload()
            // SwiftUI 的视图树是陆续拆掉的，稍后再把空闲的内存页还给系统。
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
    }
}
