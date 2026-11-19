import Foundation

/// 本地的常用语替换规则，以及分句拼接。
struct TextPostProcessor {
    private let rules: [(String, String)]

    init(replacements: [(String, String)]) {
        rules = replacements.sorted { $0.0.count > $1.0.count }
    }

    func apply(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for (trigger, value) in rules where out.contains(trigger) {
            out = out.replacingOccurrences(of: trigger, with: value)
        }
        return out
    }

    /// 中文直接拼接；英文单词之间补一个空格。
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts where !part.isEmpty {
            if let last = out.last, let first = part.first, needsSpace(last, first) {
                out.append(" ")
            }
            out += part
        }
        return out
    }

    private static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        guard a.isASCII, b.isASCII, !a.isWhitespace, !b.isWhitespace else { return false }
        return (a.isLetter || a.isNumber || ",.;:!?".contains(a)) && (b.isLetter || b.isNumber)
    }
}
