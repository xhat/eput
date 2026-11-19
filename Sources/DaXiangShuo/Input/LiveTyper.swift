import AppKit
import CoreGraphics
import Foundation

/// 往当前焦点输入框发合成按键。
final class KeyEmitter: @unchecked Sendable {
    static let shared = KeyEmitter()

    private let source: CGEventSource?
    private static let backspaceKey: CGKeyCode = 51
    private static let vKey: CGKeyCode = 9
    private static let cKey: CGKeyCode = 8
    private static let leftKey: CGKeyCode = 123
    private static let rightKey: CGKeyCode = 124
    private static let uKey: CGKeyCode = 21
    private static let eKey: CGKeyCode = 14
    private static let kKey: CGKeyCode = 40
    /// 一个 CGEvent 最多携带 20 个 UTF-16 字符。
    private static let maxUnitsPerEvent = 20

    private init() {
        // privateState：不继承用户正按着的修饰键（比如按住说话的右 Option），否则退格会变成删词。
        source = CGEventSource(stateID: .privateState)
        // 默认合成事件后会屏蔽本地键盘 0.25 秒，那样会漏掉松开快捷键的事件。
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
    }

    func backspace(_ count: Int) {
        guard count > 0 else { return }
        // 一性次全发出去：事件在系统队列里有先后，不需要中间等，
        // 真正慢的是目标 App 一个个处理按键，不是我们发送。
        for _ in 0..<count { postKey(Self.backspaceKey, flags: []) }
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        var chunk: [UniChar] = []
        chunk.reserveCapacity(Self.maxUnitsPerEvent)
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > Self.maxUnitsPerEvent {
                postUnicode(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { postUnicode(chunk) }
    }

    func pasteShortcut() {
        postKey(Self.vKey, flags: .maskCommand)
    }

    /// 选到行首：整行替换用它来框出「光标前这一行」。
    func selectToLineStart() {
        postKey(Self.leftKey, flags: [.maskCommand, .maskShift])
    }

    func copySelection() {
        postKey(Self.cKey, flags: .maskCommand)
    }

    /// 收起选中区（选中区在光标前面，→ 会把光标放回选中区的末尾，也就是原来的光标处）。
    func collapseSelection() {
        postKey(Self.rightKey, flags: [])
    }

    // MARK: 终端的行编辑（readline 那套）

    /// ⌃E：光标回到行尾。
    func lineEnd() { postKey(Self.eKey, flags: .maskControl) }

    /// ⌃U：从光标剪到行首（光标在行尾时就是清空整行），内容进终端的 kill ring。
    func killToLineStart() { postKey(Self.uKey, flags: .maskControl) }

    /// ⌃K：从光标删到行尾（终端/行编辑器通用）。
    func killToLineEnd() { postKey(Self.kKey, flags: .maskControl) }


    private func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func postUnicode(_ units: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buffer in
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            }
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

/// 实时逐字上屏：目标文本一变，就和已上屏文本比较，退格删掉不一致的尾部再补打。
/// 后续结果原地覆盖前文，而不是往后追加。
final class LiveTyper: @unchecked Sendable {
    /// 一次要退格这么多个字时，改用辅助功能接口整体替换：
    /// 字多的时候逐字删除在屏幕上看得见地慢（整段整理经常会删掉几十个字）。
    private static let bulkThreshold = 8
    private let queue = DispatchQueue(label: "typer", qos: .userInteractive)
    private let emitter = KeyEmitter.shared
    /// 允许在对端 App 支持时用剪贴板一步替换整段（设置里的「自动」）。
    private let clipboardReplacement: Bool
    /// 终端里怎么落字。
    private let terminalMode: TerminalReplaceMode
    /// 终端里这一行原有的内容（我们记的账）。返回 nil 表示不知道，就不能整行清。
    private let linePrefix: () -> String?

    // 用 lock 保护，任何线程都可以调用 update。
    private let lock = UnfairLock()
    private var pending: [Character]?
    private var scheduled = false
    private var enabled: Bool

    // 只在 queue 上访问。
    private var typed: [Character] = []
    /// 用户干预后，目标文本前面这么多字已经固定，不再退格修改。
    private var frozenCount = 0

    /// enabled 为 false 时先只记录目标文本，等上一轮听写全部上屏完再开始打字。
    init(enabled: Bool, clipboardReplacement: Bool = true,
         terminalMode: TerminalReplaceMode = .keysOnly,
         linePrefix: @escaping () -> String? = { nil }) {
        self.enabled = enabled
        self.clipboardReplacement = clipboardReplacement
        self.terminalMode = terminalMode
        self.linePrefix = linePrefix
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    func update(_ target: String) {
        let characters = Array(target)
        let schedule: Bool = lock.withLock {
            pending = characters
            guard enabled, !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    func enable() {
        let schedule: Bool = lock.withLock {
            enabled = true
            guard pending != nil, !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    func freeze() {
        queue.async {
            self.frozenCount += self.typed.count
            self.typed.removeAll()
        }
    }

    /// 等所有已提交的上屏操作执行完。
    func whenIdle(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// 队列空闲时立刻执行；正在打字时来的新结果合并成最新一份，中间状态直接丢弃。
    private func drain() {
        while true {
            let next: [Character]? = lock.withLock {
                let value = pending
                pending = nil
                if value == nil { scheduled = false }
                return value
            }
            guard let target = next else { return }
            apply(target)
        }
    }

    private func apply(_ target: [Character]) {
        let desired = frozenCount < target.count ? Array(target[frozenCount...]) : []
        // 用公共前缀 + 公共后缀夹出中间真正变了的那一段：
        // 「三点啊不对五点」→「五点」这种删改只动几个字，不用把后面的词全删了重打。
        let limit = min(typed.count, desired.count)
        var prefix = 0
        while prefix < limit, typed[prefix] == desired[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              typed[typed.count - 1 - suffix] == desired[desired.count - 1 - suffix] { suffix += 1 }

        let removed = String(typed[prefix..<(typed.count - suffix)])
        let kept = String(typed[(typed.count - suffix)...])
        let added = String(desired[prefix..<(desired.count - suffix)])
        guard !removed.isEmpty || !added.isEmpty else { return }

        // 删除量一大就走一步到位的替换：辅助功能 → 终端行编辑 → 整行粘贴 → 逐字按键。
        if removed.count + suffix >= Self.bulkThreshold {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            let terminal = TerminalReplacer.isFrontmostTerminal
            if FocusedFieldEditor.shared.replace(removed, keepingSuffix: kept, with: added) {
                Log.app.notice("\(app, privacy: .public) 辅助功能替换：删 \(removed.count, privacy: .public) 增 \(added.count, privacy: .public)")
                typed = desired
                return
            }
            if terminal, terminalMode == .direct, frozenCount == 0 {
                // ⌃U 清的是「整行」：只有确定这一行的内容全是我们自己打进去的才敢用。
                if let prefix = linePrefix() {
                    // 整行 = 我们记下的原有内容 + 这次应该变成的文本。
                    if TerminalReplacer.replaceLine(with: prefix + String(desired)) {
                        Log.app.notice("\(app, privacy: .public) 终端清行替换：整行 \(prefix.count + desired.count, privacy: .public) 字（改 \(removed.count, privacy: .public) → \(added.count, privacy: .public)）")
                        typed = desired
                        return
                    }
                } else {
                    Log.app.notice("\(app, privacy: .public) 这一行内容不确定，没敢整行清掉，退回按键")
                }
            }
            // 终端里不要走「整行粘贴」：那一步是把文字送进程序，粘贴不会覆盖屏幕上的选中高亮，
            // 万一对上了反而会多贴一份。终端只走上面那条行编辑路线。
            if clipboardReplacement, !terminal,
               LineReplacer.replaceLine(typed: String(typed), with: String(desired)) {
                Log.app.notice("\(app, privacy: .public) 整行粘贴替换：删 \(removed.count, privacy: .public) 增 \(added.count, privacy: .public)")
                typed = desired
                return
            }
            // 这里报真实按键数：退格会连「后面没变的那段」一起删掉再打回去，
            // 所以看到的删除量常常比真正改变的字符多。
            Log.app.notice("\(app, privacy: .public) 退回按键：退格 \(removed.count + suffix, privacy: .public) 重打 \(added.count + suffix, privacy: .public)（实际改变 \(removed.count, privacy: .public) → \(added.count, privacy: .public)）")
        }

        emitter.backspace(removed.count + suffix)
        let retype = added + kept
        if !retype.isEmpty { emitter.type(retype) }
        typed = desired
    }
}
