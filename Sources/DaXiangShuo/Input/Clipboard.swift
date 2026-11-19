import AppKit

/// 临时占用系统剪贴板的租约：开始前把用户原来的内容整份存下来，用完原样还回去。
/// 我们的临时内容会打上「临时 / 保密」标记，Raycast、Maccy、Paste 这类剪贴板管理器
/// 就不会把它记进历史；用户中途自己复制了别的东西时，我们也不去覆盖人家的新内容。
final class ClipboardLease {
    /// 超过这个体积就别折腾了：复制一份可能很慢，也可能复制不全。
    private static let maxBytes = 2 * 1024 * 1024
    /// 剪贴板管理器认的两个约定类型，见 nspasteboard.org。
    private static let quietTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    private let items: [NSPasteboardItem]
    /// 我们自己最后写到剪贴板上的文字。
    private var ownedText: String?
    /// 我们自己最后一次写入之后的 changeCount。
    private var ownedChangeCount: Int?

    private init(items: [NSPasteboardItem]) {
        self.items = items
    }

    /// 剪贴板里的东西没法安全复制（Finder 的文件承诺、超大内容）时返回 nil，
    /// 调用方就老老实实走按键，不要动用户的剪贴板。
    static func begin() -> ClipboardLease? {
        let pasteboard = NSPasteboard.general
        var total = 0
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard !item.types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("promise") })
            else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= maxBytes else { return nil }
                copy.setData(data, forType: type)
            }
            copies.append(copy)
        }
        return ClipboardLease(items: copies)
    }

    /// 写入我们的临时内容（纯文本 + 临时标记）。
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in Self.quietTypes { item.setString("1", forType: type) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        ownedText = text
        ownedChangeCount = pasteboard.changeCount
    }

    /// 目标 App 因为我们的按键（Cmd+C）往剪贴板里写了东西：那也算我们的状态，
    /// 否则之后会误判成「用户自己复制了东西」而不肯恢复。
    func adoptCurrentContent() {
        ownedText = Self.current
        ownedChangeCount = NSPasteboard.general.changeCount
    }

    /// 把用户原来的内容还回去。只有剪贴板里还是我们自己写的东西时才还，
    /// 用户（或别的 App）中途写了新内容就不动。
    func release() {
        let pasteboard = NSPasteboard.general
        let current = Self.current
        let stillOurs = current == ownedText
            || (current == nil && pasteboard.changeCount == ownedChangeCount)
        guard stillOurs else { return }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
        ownedText = Self.current
        ownedChangeCount = pasteboard.changeCount
    }

    static var current: String? {
        NSPasteboard.general.string(forType: .string)
    }
}
