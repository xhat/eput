import AppKit
import CoreGraphics

/// 本程序合成的按键事件都带这个标记，监听时跳过，避免把自己打的字当成用户干预。
let syntheticEventMarker: Int64 = 0x44_58_53_48

/// 全局快捷键。CGEventTap 跑在独立线程的 RunLoop 上，回调里只记录时刻并转发，不做任何耗时操作。
final class HotkeyMonitor: @unchecked Sendable {
    /// 参数是事件发生时的 mach_absolute_time。
    var onPTTDown: ((UInt64) -> Void)?
    var onPTTUp: ((UInt64) -> Void)?
    var onToggle: ((UInt64) -> Void)?
    /// 听写过程中用户自己按了键（pttHeld 表示当时按住说话的修饰键仍按着）。
    var onUserKey: ((_ pttHeld: Bool) -> Void)?
    /// 用户自己敲了任何普通键（不含我们合成的事件、不含快捷键本身），带上键码。
    /// 用来判断「这一行有没有用户自己打的字」，终端里整行清掉之前要看它。
    var onUserTyping: ((_ keyCode: Int64) -> Void)?
    var onUserMouse: (() -> Void)?

    /// 单独点按修饰键作为切换键时，按下到松开不超过这个时长才算一次点按。
    private static let tapMaxMs: Double = 400

    private let lock = UnfairLock()
    private var hold: Hotkey?
    private var toggle: Hotkey?
    private var holdDown = false
    private var toggleTapStart: UInt64 = 0
    private var sessionActive = false
    private var suspended = false
    private var tap: CFMachPort?
    private var thread: Thread?
    private var retryTimer: Timer?

    var isRunning: Bool { lock.withLock { tap != nil } }

    func configure(hold: Hotkey?, toggle: Hotkey?) {
        lock.withLock {
            self.hold = hold
            self.toggle = toggle
            holdDown = false
            toggleTapStart = 0
        }
    }

    /// 只在听写期间才上报普通按键和鼠标点击，平时不打扰主线程。
    func setSessionActive(_ active: Bool) {
        lock.withLock { sessionActive = active }
    }

    /// 在设置里录制快捷键时暂停响应，免得按下旧快捷键就开始听写。
    func setSuspended(_ value: Bool) {
        lock.withLock {
            suspended = value
            holdDown = false
            toggleTapStart = 0
        }
    }

    /// 没有辅助功能权限时创建会失败，每 2 秒重试一次，授权后自动生效。
    func start() {
        if installTap() {
            Log.app.info("事件监听就绪")
            return
        }
        Log.app.info("事件监听创建失败，等待辅助功能授权")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.installTap() {
                timer.invalidate()
                self.retryTimer = nil
                Log.app.info("事件监听就绪（已获得辅助功能授权）")
            }
        }
    }

    private func installTap() -> Bool {
        guard lock.withLock({ tap == nil }) else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        lock.withLock { tap = port }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "hotkey.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        Log.app.info("全局快捷键已启用")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return pass
        }

        let now = HostTime.now()
        lock.lock()
        let hold = hold
        let toggle = toggle
        let active = sessionActive
        let paused = suspended
        lock.unlock()
        guard !paused else { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawFlags = event.flags.rawValue

        switch type {
        case .flagsChanged:
            if let hold, hold.kind == .modifier, keyCode == hold.keyCode {
                let down = rawFlags & hold.flags != 0
                let wasDown = lock.withLock { holdDown }
                if down, !wasDown {
                    lock.withLock { holdDown = true }
                    onPTTDown?(now)
                } else if !down, wasDown {
                    lock.withLock { holdDown = false }
                    onPTTUp?(now)
                }
            }
            if let toggle, toggle.kind == .modifier, keyCode == toggle.keyCode {
                if rawFlags & toggle.flags != 0 {
                    lock.withLock { toggleTapStart = now }
                } else {
                    let start = lock.withLock { () -> UInt64 in
                        defer { toggleTapStart = 0 }
                        return toggleTapStart
                    }
                    if start != 0, HostTime.ms(from: start, to: now) < Self.tapMaxMs { onToggle?(now) }
                }
            }
            return pass

        case .keyDown:
            // 修饰键按住期间按了别的键，说明是组合快捷键，不算一次单独点按。
            lock.withLock { toggleTapStart = 0 }
            let modifiers = rawFlags & Hotkey.comboMask
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let hold, hold.kind == .combo, keyCode == hold.keyCode {
                let wasDown = lock.withLock { holdDown }
                if wasDown { return nil }
                if modifiers == hold.flags {
                    if !isRepeat {
                        lock.withLock { holdDown = true }
                        onPTTDown?(now)
                    }
                    return nil
                }
            }
            if let toggle, toggle.kind == .combo, keyCode == toggle.keyCode, modifiers == toggle.flags {
                if !isRepeat { onToggle?(now) }
                return nil
            }
            if !isRepeat { onUserTyping?(keyCode) }
            let modifierHeld = hold?.kind == .modifier && lock.withLock { holdDown }
            if active || modifierHeld { onUserKey?(modifierHeld) }
            return pass

        case .keyUp:
            if let hold, hold.kind == .combo, keyCode == hold.keyCode, lock.withLock({ holdDown }) {
                lock.withLock { holdDown = false }
                onPTTUp?(now)
                return nil
            }
            if let toggle, toggle.kind == .combo, keyCode == toggle.keyCode,
               rawFlags & Hotkey.comboMask == toggle.flags {
                return nil
            }
            return pass

        default:
            if active { onUserMouse?() }
            return pass
        }
    }
}
