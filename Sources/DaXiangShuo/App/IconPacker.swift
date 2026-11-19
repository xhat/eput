import Foundation

/// 把 iconset 目录里的 PNG 拼成 .icns。
///
/// 关键点：16×16 / 32×32 必须用 iconutil 生成的 `ic04` / `ic05`（苹果自己的原始 ARGB 块）。
/// 这两个尺寸如果塞 PNG，macOS 的图标读取器会把 PNG 字节当像素画出来，
/// Finder、系统设置的列表里就是一块彩色噪点。所以 PNG 只用 32px 以上，
/// 小尺寸直接从 iconutil 产出的基础 icns 里抄。
enum IconPacker {
    /// 顺序和 iconutil 的产物一致。注意这里面没有 icp4 / icp5：这两个 tag 在
    /// macOS 上会被当成原始像素解码，PNG 数据放进去就是花屏。
    private static let pngEntries: [(tag: String, file: String)] = [
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
    ]

    /// 必须来自 iconutil 的两档小尺寸。
    private static let rawTags = ["ic04", "ic05"]

    /// base 是 iconutil 生成的基础 icns，从中取 ic04/ic05；找不到时退回「不放小尺寸」的版本
    /// （macOS 会用 128px 缩放，能看但略糊），绝不写入会花屏的 PNG 小图。
    @discardableResult
    static func pack(iconset: String, base: String?, output: String) -> Bool {
        let directory = URL(fileURLWithPath: iconset)

        var blocks: [(tag: String, data: Data)] = []
        if let base, let source = readBlocks(inICNS: base) {
            for tag in rawTags {
                if let data = source[tag] { blocks.append((tag, data)) }
            }
        }
        if blocks.count != rawTags.count {
            Log.app.error("基础 icns 里缺少 ic04/ic05，小尺寸图标会略微发虚")
        }

        var written: [String] = []
        for entry in pngEntries {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(entry.file)) else {
                Log.app.error("图标源文件缺失：\(entry.file, privacy: .public)")
                return false
            }
            blocks.append((entry.tag, data))
            written.append(entry.tag)
        }

        // 总长度必须把所有块（含从基础 icns 抄来的 ic04/ic05）都算进去，
        // 少算几字节的话 macOS 会把文件当成截断的，图标只画出灰底。
        let total = 8 + blocks.reduce(0) { $0 + 8 + $1.data.count }
        var out = Data("icns".utf8)
        out.append(bigEndian: UInt32(total))
        for (tag, data) in blocks {
            out.append(Data(tag.utf8))
            out.append(bigEndian: UInt32(data.count + 8))
            out.append(data)
        }
        do {
            try out.write(to: URL(fileURLWithPath: output))
        } catch {
            Log.app.error("写 icns 失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
        Log.app.notice("icns 已生成：\(out.count) 字节，块 \(written.joined(separator: ","), privacy: .public)")
        return true
    }

    /// 读出 icns 里的各个块。
    private static func readBlocks(inICNS path: String) -> [String: Data]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 8,
              String(decoding: data.prefix(4), as: UTF8.self) == "icns" else {
            Log.app.error("基础 icns 不合法：\(path, privacy: .public)")
            return nil
        }
        var result: [String: Data] = [:]
        var offset = 8
        while offset + 8 <= data.count {
            let start = data.startIndex + offset
            let tag = String(decoding: data[start..<start + 4], as: UTF8.self)
            let length = Int(data[start + 4..<start + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length >= 8, offset + length <= data.count else { break }
            result[tag] = data[(start + 8)..<(start + length)]
            offset += length
        }
        return result
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(value >> 24 & 0xFF))
        append(UInt8(value >> 16 & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
