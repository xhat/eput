import AppKit
import Carbon.HIToolbox
import Foundation

/// 终端里的整段替换。
///
/// 终端没有「选中一块文字、粘贴覆盖」这回事：粘贴只是把文字送进程序，选中只是屏幕上的高亮。
/// 而想读回这一行的内容，就得先发 ⌃A / ⇧End 把光标移过去——万一那个 App 不认 ⌃E，
/// 光标就回不来，接下来的退格会删到前面的字。所以 1.0.19 起不再发这些「探测」按键：
/// 要么直接用 ⌃U 清行重打（可选，快），要么老老实实逐字退格。
enum TerminalReplacer {
    /// 认得出的终端 / 终端宿主。只在这些 App 上走这条路。
    static let terminalApps: Set<String> = [
        "dev.herdr.app",            // Herdr
        "io.appmakes.otty",         // Otty
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "org.tabby",
        "com.termius.mac",
    ]

    /// 当前前台 App 是不是终端。
    static var isFrontmostTerminal: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalApps.contains(id)
    }

    /// 清整行再打上新的整行文本：⌃U 一个键把整行剪进 kill ring，然后把 text 打上去。
    ///
    /// 不读内容、不碰剪贴板，所以快；`text` 必须是「这一行应该变成的全部内容」
    /// （已经包含我们记账里这一行原有的部分）。调用方只在这一行确实只有我们打进去的字时才用。
    static func replaceLine(with text: String) -> Bool {
        guard !text.isEmpty, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              terminalApps.contains(id) else { return false }

        KeyEmitter.shared.lineEnd()          // 光标稳在行尾，⌃U 才等于「清空整行」
        usleep(40_000)
        KeyEmitter.shared.killToLineStart()  // ⌃U
        usleep(80_000)
        KeyEmitter.shared.type(Self.withoutNewlines(text))
        return true
    }

    /// 终端里一个换行就等于替用户按了回车（可能直接执行命令），一律换成空格。
    private static func withoutNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

}
