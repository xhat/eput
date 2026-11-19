import AppKit

/// 兜底模式：说完后一次性粘贴，结束后恢复用户原来的剪贴板。
enum PasteInserter {
    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        KeyEmitter.shared.pasteShortcut()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
