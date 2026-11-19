import Foundation

/// L2「意图转录」的结果：整理后的正文 + 可核对的逐条改动。
struct IntentRewrite: Equatable {
    struct Edit: Equatable {
        /// 原文里要被替换掉的连续片段（删除时 `to` 为空）。
        var from: String
        var to: String
    }

    var text: String
    var edits: [Edit]
}

/// 把字面转录整理成「用户想写的那句话」。
///
/// 只做三件事：删口头噪音、合并自我修正、修错别字。不做总结/扩写，也不改事实。
/// 模型输出必须能通过 `validate` 才算数，过不了就退回本地清理的结果。
enum IntentRewriter {
    /// 太短的一句话不值得再走一次模型（延迟不值）。
    static let minimumLength = 6

    static func shouldRewrite(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength
    }

    static let systemPrompt = """
        你是语音输入法的“意图转录器”。输入是语音识别的字面结果，已经分句。

        允许：
        1. 删除填充词、口头语、口吃和重复；
        2. 合并自我修正：说话人改口时只保留最终版本（“明天下午三点……啊不对五点” → “明天下午五点”）；
        3. 修正错别字、同音字和标点。

        禁止：新增原话里没有的信息；改动事实、时间、数字、金额、否定、人称；总结、扩写、翻译；把陈述句改成疑问句。
        不要输出列表、标题或项目符号，只输出整理后的正文。

        只输出 JSON，不要代码块、不要解释：
        {"text":"整理后的正文","edits":[{"from":"原文里要替换掉的连续片段","to":"替换成什么，纯删除填空字符串"}]}
        不需要修改时 text 与原文相同、edits 为空数组。
        """

    // MARK: 校验

    /// 一次改写是否可信：长度由调用方把关，这里管「不许凭空造内容」。
    static func validate(_ rewrite: IntentRewrite, original: String, glossary: [String]) -> Bool {
        let text = rewrite.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text == original { return true }

        // 1. 数字/时间：结果里出现的每个数字都必须在原文里出现过。
        //    允许原文的数字被删掉（那正是自我修正），但不允许换成一个新的数字。
        guard numbers(in: text).isSubset(of: numbers(in: original)) else { return false }

        // 2. 链接和邮箱不能凭空出现。
        let lowerOriginal = original.lowercased()
        for token in links(in: text) where !lowerOriginal.contains(token.lowercased()) { return false }

        // 3. 英文单词必须在原文或词典里出现过。
        let allowed = Set(latinWords(in: original))
            .union(glossary.flatMap { latinWords(in: $0) })
        for word in latinWords(in: text) where !allowed.contains(word) { return false }

        // 4. 否定不能新增（“我要”改成“我不要”这种必须拦住）。
        guard negations(in: text).isSubset(of: negations(in: original)) else { return false }

        // 5. 每一处改动都要能在原文里定位，否则说明模型在编。
        for edit in rewrite.edits where !edit.from.isEmpty {
            guard original.contains(edit.from) else { return false }
        }
        return true
    }

    // MARK: 词法

    private static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// 阿拉伯数字，以及「三点」「五月」「两块」这类中文数量。
    static func numbers(in text: String) -> Set<String> {
        var out = Set(matches(text, #"\d+(?:[.,:]\d+)*"#))
        out.formUnion(matches(text, #"[零一二三四五六七八九十百千万两]+(?=[点分秒月日号元块岁个度])"#))
        return out
    }

    static func links(in text: String) -> [String] {
        matches(text, #"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+"#)
    }

    static func latinWords(in text: String) -> [String] {
        matches(text, #"[A-Za-z][A-Za-z0-9_'+.-]*"#).map { $0.lowercased() }
    }

    static func negations(in text: String) -> Set<String> {
        Set(matches(text, #"不是|不要|不用|不能|不会|没有|别|未|无|not|never|don't|doesn't|isn't|no"#)
            .map { $0.lowercased() })
    }
}
