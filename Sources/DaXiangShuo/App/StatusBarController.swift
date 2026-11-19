import AppKit

final class StatusBarController: NSObject {
    var onOpenMain: (() -> Void)?
    var onRestoreRaw: (() -> Void)?
    var canRestoreRaw: () -> Bool = { false }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let idleImage = IconRenderer.statusImage(wavePhase: nil)
    private lazy var waveImages = (0..<4).map { IconRenderer.statusImage(wavePhase: $0) }
    private var waveTimer: Timer?
    private var wavePhase = 0
    private let menu = StatusMenu()

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = idleImage
        button.imagePosition = .imageOnly
        button.toolTip = "大象说"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func setState(_ state: DictationController.State) {
        guard let button = item.button else { return }
        switch state {
        case .idle:
            stopWaves()
            button.appearsDisabled = false
            button.image = idleImage
        case .recording:
            button.appearsDisabled = false
            startWaves()
        case .draining:
            stopWaves()
            button.image = idleImage
            button.appearsDisabled = true
        }
    }

    private func startWaves() {
        guard waveTimer == nil else { return }
        wavePhase = 0
        item.button?.image = waveImages[0]
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.wavePhase = (self.wavePhase + 1) % self.waveImages.count
            self.item.button?.image = self.waveImages[self.wavePhase]
        }
        RunLoop.main.add(timer, forMode: .common)
        waveTimer = timer
    }

    private func stopWaves() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            menu.close()
            onOpenMain?()
        }
    }

    private func showMenu() {
        guard let button = item.button else { return }
        if menu.isShown {
            menu.close()
            return
        }
        var entries: [StatusMenu.Entry] = [
            .init(title: "打开主界面") { [weak self] in self?.onOpenMain?() },
        ]
        if canRestoreRaw() {
            entries.append(.init(title: "恢复上一句原文") { [weak self] in self?.onRestoreRaw?() })
        }
        entries.append(.init(title: "退出大象说") { NSApp.terminate(nil) })
        menu.show(entries: entries, below: button)
    }
}
