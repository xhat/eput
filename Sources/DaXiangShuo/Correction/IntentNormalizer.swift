import Foundation

/// 本地、确定性的语音清理，不联网、不改意思，只做「删除」和「合并」。
///
/// 覆盖三件事：
/// 1. 填充词：嗯 / 呃 / 诶 / um / uh / "you know" / "就是说" 之类；
/// 2. 口吃：我我我觉得、这个这个、就是说就是说；
/// 3. 重复：短句整段重复（只合并白名单里的常见口头重复，宁可漏也不误删）。
///
/// 语义层面的自我修正（“三点……啊不对五点”）不在这里做——规则判断不了哪一段该丢，
/// 放在整段意图改写（L2）里交给模型。
enum IntentNormalizer {
    struct Options: Equatable {
        var fillers = true
        var stutters = true
        var repeats = true

        static let off = Options(fillers: false, stutters: false, repeats: false)
        /// 设置里只有一个开关：打开就三件事全做。
        static func enabled(_ on: Bool) -> Options {
            on ? Options() : .off
        }
    }

    static func apply(_ text: String, options: Options = Options()) -> String {
        guard !text.isEmpty, options != .off else { return text }
        var out = text
        if options.fillers { out = removeFillers(out) }
        if options.stutters { out = collapseStutters(out) }
        if options.repeats { out = collapseRepeats(out) }
        return tidy(out)
    }

    // MARK: 填充词

    /// 绝不会出现在词里的语气词：任何位置都删。
    private static let standaloneInterjections = ["嗯", "呃", "唉", "诶", "唔"]
    /// 可能出现在词里的单字（金额、哎呀…）：只有左右都是停顿/边界时才删。
    private static let boundaryInterjections = ["额", "啊", "哦", "噢", "哎"]
    /// 英文语气词：必须有空格/标点夹着，否则会命中 album 里的 um。
    private static let englishInterjections = ["um", "uh", "erm", "hmm"]
    /// 只在被标点/空格夹住时删，或紧跟着也是同一个词（那个那个）时删。
    private static let softFillers = ["那个", "这个", "就是说", "然后就是", "反正就是",
                                      "怎么说呢", "你知道吧", "你知道", "就是说就是",
                                      "you know", "i mean", "sort of", "kind of"]

    private static let pauseMarks = "，。！？；：、,.!?;:\n…"

    private static func removeFillers(_ text: String) -> String {
        var out = text

        for word in standaloneInterjections {
            out = removeToken(out, word, requirePauseBefore: false, requirePauseAfter: false, eatFollowingPause: true)
        }
        for word in boundaryInterjections + englishInterjections {
            out = removeToken(out, word, requirePauseBefore: true, requirePauseAfter: true, eatFollowingPause: true)
        }

        // “那个那个”“就是说就是说”这种叠用：留一份。
        for word in softFillers {
            let doubled = word + word
            while out.range(of: doubled, options: [.caseInsensitive]) != nil {
                out = out.replacingOccurrences(of: doubled, with: word, options: [.caseInsensitive])
            }
        }

        // 软填充词：被标点/空格夹住才删（“那个”常常是实词，不能乱动）。
        for word in softFillers.sorted(by: { $0.count > $1.count }) {
            out = removeToken(out, word, requirePauseBefore: true, requirePauseAfter: true, eatFollowingPause: true)
        }

        return out
    }

    /// 删掉某个词：before / after 要求必须是停顿或边界，否则不删。
    private static func removeToken(_ text: String, _ token: String,
                                    requirePauseBefore: Bool, requirePauseAfter: Bool,
                                    eatFollowingPause: Bool) -> String {
        var out = text
        var searchStart = out.startIndex
        while let range = out.range(of: token, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
            let before = range.lowerBound == out.startIndex ? nil : out[out.index(before: range.lowerBound)]
            let after = range.upperBound == out.endIndex ? nil : out[range.upperBound]

            let beforeOK = !requirePauseBefore || before == nil || pauseMarks.contains(before!) || before == " "
            let afterOK = !requirePauseAfter || after == nil || pauseMarks.contains(after!) || after == " "
            guard beforeOK, afterOK else {
                searchStart = range.upperBound
                continue
            }

            var dropEnd = range.upperBound
            if eatFollowingPause {
                while dropEnd < out.endIndex, pauseMarks.contains(out[dropEnd]) || out[dropEnd] == " " {
                    dropEnd = out.index(after: dropEnd)
                }
            }
            out.removeSubrange(range.lowerBound..<dropEnd)
            searchStart = range.lowerBound
        }
        return out
    }

    // MARK: 口吃与重复

    /// 单个字重复：只处理代词和判断词（“我我我觉得”“是是是”），不动“看看”“刚刚”这类正常叠词。
    private static let stutterChars: Set<Character> = ["我", "你", "他", "她", "它", "这", "那", "就", "是"]
    /// 成词重复：只合并这些高频口头重复，宁可漏。
    private static let repeatPhrases = ["我觉得", "这个", "那个", "就是", "然后", "所以", "因为", "但是",
                                        "其实", "反正", "我们", "你们", "他们", "不是", "可以", "对不",
                                        "today", "i think", "you know"]

    private static func collapseStutters(_ text: String) -> String {
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            guard stutterChars.contains(chars[i]) else { i += 1; continue }
            var run = 1
            while i + run < chars.count, chars[i + run] == chars[i] { run += 1 }
            if run >= 2 {
                chars.removeSubrange((i + 1)..<(i + run))
            }
            i += 1
        }
        return String(chars)
    }

    private static func collapseRepeats(_ text: String) -> String {
        var out = text
        for phrase in repeatPhrases.sorted(by: { $0.count > $1.count }) {
            let doubled = phrase + phrase
            while out.range(of: doubled, options: [.caseInsensitive]) != nil {
                out = out.replacingOccurrences(of: doubled, with: phrase, options: [.caseInsensitive])
            }
        }
        return out
    }

    // MARK: 收尾

    /// 去掉删除操作留下的重复标点、句首逗号、首尾空格。
    private static func tidy(_ text: String) -> String {
        var out = text
        // 连续标点合成一个（保留最后一个，问号感叹号更有信息量）。
        out = out.replacingOccurrences(of: "，,", with: "，")
        out = out.replacingOccurrences(of: ",，", with: "，")
        out = out.replacingOccurrences(of: "，，", with: "，")
        out = out.replacingOccurrences(of: ",,", with: ",")
        out = out.replacingOccurrences(of: "。。", with: "。")
        out = out.replacingOccurrences(of: "，。", with: "。")
        out = out.replacingOccurrences(of: "，！", with: "！")
        out = out.replacingOccurrences(of: "，？", with: "？")
        out = out.replacingOccurrences(of: " ，", with: "，")
        out = out.replacingOccurrences(of: " ,", with: ",")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }

        // 句首的逗号、空格没有意义。
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = out.first, first == "，" || first == "," || first == "、" {
            out.removeFirst()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
