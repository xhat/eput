import AppKit
import Carbon.HIToolbox
import Foundation

/// 把「光标前这一行」整体换成新文本：借剪贴板一次粘贴搞定，替掉几十个退格。
///
/// 只有能证明这一行**除了我们刚打的字什么都没有**时才动手：
/// 先 Shift+Cmd+← 选到行首，再 Cmd+C 读回来比对。对不上就按 → 收起选中区
/// （光标回到原处，可撤销），交给逐字退格。比对不上就退格，位子也回得去。
///
/// 为什么不用 Cmd+A：全选之后一旦比对不一致，光标位置就找不回来了，
/// 之后的退格会删到别的文字。选到行首是能原样收回来的。
enum LineReplacer {
    /// 轮询剪贴板的次数与间隔：Chromium 系 App 把数据放上去是异步的。
    private static let pollCount = 12
    private static let pollInterval: useconds_t = 15_000
    /// 粘贴之后等目标 App 真正读走剪贴板，再把用户的内容还回去。
    private static let pasteSettle: useconds_t = 150_000
    /// 按键之间留一点时间给目标 App 处理。
    private static let keyGap: useconds_t = 20_000

    /// `typed` 是我们已经打上去的那段字，`replacement` 是它应该变成的样子。
    /// 返回 true 表示已整体替换（光标在末尾），false 表示调用方该退回逐字按键。
    static func replaceLine(typed: String, with replacement: String) -> Bool {
        guard !typed.isEmpty, AXIsProcessTrusted() else { return false }
        // 密码框/安全输入下不要碰剪贴板，免得把密码复制上去。
        guard !IsSecureEventInputEnabled() else { return false }
        guard let lease = ClipboardLease.begin() else {
            Log.app.notice("整行替换跳过：剪贴板内容没法安全保存")
            return false
        }

        let sentinel = "daxiangshuo-probe-\(UUID().uuidString)"
        lease.write(sentinel)                      // 用哨兵判定「复制到底动了没有」
        KeyEmitter.shared.selectToLineStart()
        usleep(keyGap)
        KeyEmitter.shared.copySelection()

        guard let copied = waitForCopy(after: sentinel) else {
            // 什么都没复制上来：多半是没选中东西，也可能这个 App 不让复制。
            // 这时候别按 → （没有选中区时按一下会把光标右移一格），直接退回按键。
            lease.release()
            return false
        }
        // 这次复制是我们按的 Cmd+C 造成的，记成我们自己的状态，收尾时才能把剪贴板还回去。
        lease.adoptCurrentContent()

        guard copied == typed else {
            // 这一行里还有别的字（提示符、上一次听写的文字、代码缩进）。
            // 收起选中区把光标放回原处，退回逐字退格——不会删错地方。
            KeyEmitter.shared.collapseSelection()
            usleep(keyGap)
            lease.release()
            return false
        }

        lease.write(replacement)
        KeyEmitter.shared.pasteShortcut()
        usleep(pasteSettle)
        lease.release()
        return true
    }

    /// 等复制真的把内容放上剪贴板；超时或内容没变（还是哨兵）返回 nil。
    private static func waitForCopy(after sentinel: String) -> String? {
        for _ in 0..<pollCount {
            usleep(pollInterval)
            if let text = ClipboardLease.current, text != sentinel { return text }
        }
        return nil
    }
}
