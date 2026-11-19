import ApplicationServices
import AppKit
import Foundation

/// 用辅助功能接口直接改输入框里的文字，绕过「一个字符一个退格」。
///
/// 只做一件事：把光标前面那段**我们自己刚打上去的字**换掉。
/// 动手前先把那段选中、读回来比对，确认和预期一字不差才替换；任何一步不对就
/// 返回 false，由调用方退回合成按键——宁可慢一点，也不能改到用户的别的文字。
final class FocusedFieldEditor: @unchecked Sendable {
    static let shared = FocusedFieldEditor()

    private init() {}

    /// `expected` 必须是光标前紧挨着的那段要换掉的文字，`suffix` 是它后面紧跟着、不需要动的那段
    /// （有 `suffix` 才能只换中间变了的几个字，而不是把后面一长串全删了重打）。
    /// 成功返回 true，文字已换好，光标回到原来的末尾位置。
    func replace(_ expected: String, keepingSuffix suffix: String, with replacement: String) -> Bool {
        guard !expected.isEmpty, AXIsProcessTrusted() else { return false }
        guard let element = focusedElement(),
              let caret = selectedRange(element), caret.length == 0 else { return false }

        let length = (expected as NSString).length
        let suffixLength = (suffix as NSString).length
        let start = caret.location - suffixLength - length
        guard start >= 0, setRange(element, CFRange(location: start, length: length)) else { return false }

        // 选中的必须正好是我们的那段；不是就把光标放回去，交给逐字退格。
        guard selectedText(element) == expected else {
            _ = setRange(element, caret)
            return false
        }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           replacement as CFString) == .success else {
            _ = setRange(element, caret)
            return false
        }

        // 有的 App 会「答应但不改」：把值读回来确认一下。没改就放回光标走按键；
        // 真改了才认为成功，免得上屏记录和输入框对不上，下一次退格删错地方。
        let end = start + (replacement as NSString).length + suffixLength
        if let value = attribute(element, kAXValueAttribute) as? String, value.utf16.count <= 20_000 {
            if value.hasSuffix(replacement + suffix) {
                // 改好了。
            } else if value.hasSuffix(expected + suffix) {
                _ = setRange(element, caret)
                return false
            }
        }
        _ = setRange(element, CFRange(location: end, length: 0))
        return true
    }

    /// 排障用（`--probe-ax`）：把三种找焦点元素的办法各自的结果打出来，
    /// 好判断某个 App 到底支持到什么程度。
    func debugSnapshot() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        guard AXIsProcessTrusted() else { return "前置=\(front) 辅助功能未授权" }
        var lines = ["前置=\(front)"]
        for (name, candidate) in zip(["系统级", "前台 App", "前台窗口"], focusCandidates()) {
            let (element, error) = candidate()
            guard let element else {
                lines.append("\(name)：失败（AXError \(error.rawValue)）")
                continue
            }
            let role = (attribute(element, kAXRoleAttribute) as? String) ?? "-"
            let range = selectedRange(element).map { "\($0.location),\($0.length)" } ?? "-"
            let value = (attribute(element, kAXValueAttribute) as? String) ?? "<无 AXValue>"
            lines.append("\(name)：role=\(role) 光标=\(range) 值=\(value.suffix(40))")
        }
        return lines.joined(separator: "\n")
    }

    /// 排障用（`--dump-ax`）：把前台 App 的属性名和前两级界面树打出来，
    /// 用来判断某个 App 到底有没有把无障碍树打开。
    func dumpTree() -> String {
        guard AXIsProcessTrusted() else { return "辅助功能未授权" }
        guard let app = Self.frontApp() else { return "没有前台 App" }
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        var names: CFArray?
        AXUIElementCopyAttributeNames(app, &names)
        var lines = ["App=\(name) 属性：\((names as? [String] ?? []).joined(separator: ","))"]
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            lines.append("窗口数=\(windows.count)")
            for window in windows.prefix(1) {
                walk(window, depth: 0, lines: &lines)
            }
        } else {
            lines.append("看不到窗口列表")
        }
        return lines.joined(separator: "\n")
    }

    private func walk(_ element: AXUIElement, depth: Int, lines: inout [String]) {
        guard depth <= 3, lines.count < 40 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(6) {
            let role = (attribute(child, kAXRoleAttribute) as? String) ?? "-"
            let title = (attribute(child, kAXTitleAttribute) as? String) ?? ""
            let value = (attribute(child, kAXValueAttribute) as? String) ?? ""
            lines.append(String(repeating: "  ", count: depth + 1)
                         + "role=\(role) title=\(title.prefix(24)) value=\(value.prefix(24))")
            walk(child, depth: depth + 1, lines: &lines)
        }
    }

    // MARK: 辅助功能小工具

    /// 找当前有焦点的输入框。三种问法，哪个能用用哪个：
    /// 系统级最省事，但有些 App（以及没跑起来的宿主）只回应用级/窗口级的询问。
    private func focusedElement() -> AXUIElement? {
        for candidate in focusCandidates() {
            if let element = candidate().0 { return element }
        }
        return nil
    }

    private func focusCandidates() -> [() -> (AXUIElement?, AXError)] {
        [
            {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                         kAXFocusedUIElementAttribute as CFString, &value)
                return (Self.element(value), error)
            },
            {
                guard let app = Self.frontApp() else { return (nil, .apiDisabled) }
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
                return (Self.element(value), error)
            },
            {
                guard let app = Self.frontApp() else { return (nil, .apiDisabled) }
                var window: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
                guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return (nil, error) }
                var value: CFTypeRef?
                let focused = AXUIElementCopyAttributeValue(window as! AXUIElement,
                                                           kAXFocusedUIElementAttribute as CFString, &value)
                return (Self.element(value), focused)
            },
        ]
    }

    private static func frontApp() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func selectedText(_ element: AXUIElement) -> String? {
        attribute(element, kAXSelectedTextAttribute) as? String
    }

    private func setRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
