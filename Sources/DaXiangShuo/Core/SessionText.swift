import Foundation

/// 一次听写的文本状态：已确定的句子（可能已被大模型纠正）加上正在说的那句。
/// target 就是此刻输入框里应该呈现的内容。
final class SessionText {
    struct Sentence {
        var raw: String
        var processed: String
        var corrected: String?
        var version: Int

        var display: String { corrected ?? processed }
    }

    private(set) var sentences: [Sentence] = []
    /// 胶囊预览用：包含正在说的那一句和还没放行的句子。
    /// 输入框里可能还没写（等纠错），但用户要能看到自己在说什么。
    var preview: String {
        if let finalOverride { return finalOverride }
        return TextPostProcessor.join(sentences.map(\.display) + [tail])
    }

    /// 正在说的那一句：清理 + 词典替换后的展示文本。
    private(set) var tail = ""
    /// 同一句的识别原文，给「恢复上一句原文」和历史用。
    private(set) var tailRaw = ""
    /// L2 意图改写的结果：非 nil 时上屏用它，原文照样保留在 rawText 里。
    private var finalOverride: String?
    /// 已经算进上屏文本的句子数。等大模型纠错的那一句先不画，
    /// 纠错回来一次画上——不然每句话都会「二遍识别闪一次、纠错再闪一次」。
    private var painted = Int.max
    private let processor: TextPostProcessor
    /// 纠错时往上带几句上文。
    private let contextSentences: Int
    /// 本地口头语清理。
    private let cleanup: IntentNormalizer.Options
    /// 等纠错回来再落字：正在说的那一句也先不上屏。
    /// 两者必须同时成立，否则「扣住定稿句」会让屏幕上的字先消失再出现。
    private let paintAfterCorrection: Bool
    /// 收尾时打开：最后一包文字必须上屏，不然会丢。
    private var paintsTail: Bool

    init(processor: TextPostProcessor, contextSentences: Int = 2,
         cleanup: IntentNormalizer.Options = .off, paintAfterCorrection: Bool = true) {
        self.processor = processor
        self.contextSentences = contextSentences
        self.cleanup = cleanup
        self.paintAfterCorrection = paintAfterCorrection
        self.paintsTail = !paintAfterCorrection
    }

    /// 识别原文 → 本地清理（去口头语）→ 词典替换。
    private func process(_ text: String) -> String {
        processor.apply(IntentNormalizer.apply(text, options: cleanup))
    }

    /// 上屏文本里包含的句子（等纠错的那句可能被扣着）。
    private var paintedSentences: ArraySlice<Sentence> {
        sentences.prefix(min(painted, sentences.count))
    }

    var target: String {
        if let finalOverride { return finalOverride }
        var parts = Array(paintedSentences.map(\.display))
        if paintsTail { parts.append(tail) }
        return TextPostProcessor.join(parts)
    }

    /// 最后一句先扣着不画（等纠错）。
    func holdLastSentence() {
        painted = max(0, sentences.count - 1)
    }

    /// 放行：把所有句子都算进上屏文本。
    func releaseHold() {
        painted = Int.max
    }

    /// 收尾：句子全部放行，正在说的那一句也必须上屏。
    func finishPaint() {
        painted = Int.max
        paintsTail = true
    }

    var isHolding: Bool { painted < sentences.count }

    var rawText: String {
        TextPostProcessor.join(sentences.map(\.raw) + [tailRaw])
    }

    /// 用服务端返回的完整结果刷新状态，返回新确定或内容有变化、需要纠错的句子下标。
    func apply(_ result: ASRResult) -> [Int] {
        guard !result.utterances.isEmpty else {
            if sentences.isEmpty {
                tailRaw = result.text
                tail = process(result.text)
            }
            return []
        }
        let definite = result.utterances.filter(\.definite)
        var changed: [Int] = []
        for (i, utterance) in definite.enumerated() {
            if i < sentences.count {
                guard sentences[i].raw != utterance.text else { continue }
                // 分句被服务端改写（二遍识别换了文本）：只记长度变化，不打内容。
                if utterance.text.count * 10 < sentences[i].raw.count * 7 {
                    let before = sentences[i].raw.count
                    let after = utterance.text.count
                    Log.asr.info("分句 \(i, privacy: .public) 被改写：\(before, privacy: .public) 字 → \(after, privacy: .public) 字")
                }
                sentences[i].raw = utterance.text
                sentences[i].processed = process(utterance.text)
                sentences[i].corrected = nil
                sentences[i].version += 1
            } else {
                sentences.append(Sentence(raw: utterance.text, processed: process(utterance.text),
                                          corrected: nil, version: 0))
            }
            changed.append(i)
        }
        if definite.count < sentences.count {
            // 分句数变少：服务端重新切句了。丢掉的句子已经并进前一句，这里只记一笔，
            // 方便和「前面的字被删掉」的反馈对上号。
            let before = sentences.count
            let dropped = sentences.suffix(before - definite.count).reduce(0) { $0 + $1.raw.count }
            Log.asr.info("分句数减少 \(before, privacy: .public) → \(definite.count, privacy: .public)，丢掉 \(dropped, privacy: .public) 字")
            sentences.removeLast(sentences.count - definite.count)
        }
        // 正在说的那句也走本地清理和词典替换：不然「deep sick」要等这一句定稿才变成
        // 「DeepSeek」，实时那行一直是错的。
        tailRaw = result.utterances.filter { !$0.definite }.map(\.text).joined()
        tail = process(tailRaw)
        // 又开始说下一句了：扣着的那句必须立刻放行，否则它排在 tail 前面，没法后补。
        if !tail.isEmpty { releaseHold() }
        return changed
    }

    /// 整段意图改写的结果。
    func setFinal(_ text: String) {
        finalOverride = text
    }

    /// 只有句子在纠错期间没被识别结果改过（version 相同）才生效。
    func setCorrection(_ text: String, at index: Int, version: Int) -> Bool {
        guard index < sentences.count, sentences[index].version == version,
              text != sentences[index].display else { return false }
        sentences[index].corrected = text
        return true
    }

    func context(before index: Int) -> String {
        let start = max(0, index - contextSentences)
        guard start < index else { return "" }
        return TextPostProcessor.join(sentences[start..<index].map(\.display))
    }
}
