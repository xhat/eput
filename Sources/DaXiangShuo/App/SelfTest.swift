import Foundation

/// `--self-test`：本地规则和长度策略的回归测试。
/// 跑法：`open build/大象说.app/Contents/MacOS/大象说 --self-test`
/// 或者构建后 `.../MacOS/大象说 --self-test`，失败时退出码为 1。
enum SelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures = 0
        var total = 0

        func expect(_ input: String, _ expected: String, _ note: String = "") {
            total += 1
            let actual = IntentNormalizer.apply(input)
            if actual != expected {
                failures += 1
                print("✗ [\(note)] 输入：\(input)")
                print("   期望：\(expected)")
                print("   实际：\(actual)")
            }
        }

        // 填充词
        expect("嗯，我觉得这个方案可以", "我觉得这个方案可以", "句首语气词")
        expect("呃……你说得对", "你说得对", "语气词+省略号")
        expect("我们先做 P1，嗯，再做 P2", "我们先做 P1，再做 P2", "句中语气词")
        expect("um, I think this works", "I think this works", "英文语气词")
        expect("you know, it's fine", "it's fine", "英文口头语")
        expect("这个方案，就是说，还得再看看", "这个方案，还得再看看", "口头填充短语")
        expect("金额是一百块", "金额是一百块", "不能误删实词里的字")
        expect("这首歌叫 album um, 好听", "这首歌叫 album 好听", "英文不能用子串匹配，且不留双空格")

        // 口吃与重复
        expect("我我我觉得不行", "我觉得不行", "代词口吃")
        expect("是是是，知道了", "是，知道了", "判断词口吃")
        expect("这个这个，我们先这样", "我们先这样", "重复的填充词整体去掉")
        expect("我觉得我觉得这样挺好", "我觉得这样挺好", "短句重复")
        expect("一个一个来", "一个一个来", "正常的叠用不能动")
        expect("哈哈，好的", "哈哈，好的", "拟声词不能动")
        expect("看看这个", "看看这个", "正常叠词不能动")

        // 不该动的
        expect("明天下午三点", "明天下午三点", "普通句子")
        expect("那个产品什么时候上线", "那个产品什么时候上线", "实词「那个」不能删")
        expect("这个文件改成 PDF", "这个文件改成 PDF", "自我修正留给 L2，不改口")

        // 「每天那一查」的时刻：落在 04:00–05:00 之间，已经过了就排到明天
        func checkDaily(_ hour: Int, _ minute: Int, _ note: String) {
            total += 1
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: Date())
            let now = day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            for _ in 0..<50 {
                let fire = UpdateService.nextDailyFire(after: now)
                let offset = fire.timeIntervalSince(day)
                let withinWindow = offset >= 4 * 3600 && offset < 5 * 3600
                let tomorrow = offset >= 28 * 3600 && offset < 29 * 3600
                let ok = fire > now && (withinWindow || tomorrow)
                    && (hour < 4 ? withinWindow : (hour == 4 && minute < 59 ? (withinWindow || tomorrow) : tomorrow))
                if !ok {
                    failures += 1
                    print("✗ [自动检查时间 \(note)] now=\(hour):\(minute) → \(fire)")
                    return
                }
            }
        }
        checkDaily(2, 0, "凌晨 2 点：今天 4–5 点")
        checkDaily(10, 0, "上午 10 点：明天 4–5 点")
        checkDaily(23, 30, "晚上 23:30：明天 4–5 点")
        checkDaily(4, 30, "4:30：今天剩下的或明天")

        // 意图改写的安全校验
        func guardCase(_ name: String, _ original: String, _ text: String,
                       edits: [IntentRewrite.Edit] = [], ok: Bool) {
            total += 1
            let rewrite = IntentRewrite(text: text, edits: edits)
            if IntentRewriter.validate(rewrite, original: original, glossary: []) != ok {
                failures += 1
                print("✗ [意图校验 \(name)] \(original) → \(text)，期望 \(ok ? "通过" : "拒绝")")
            }
        }
        guardCase("合并改口", "明天下午三点，啊不对五点", "明天下午五点", ok: true)
        guardCase("改数字", "明天下午三点", "明天下午五点", ok: false)
        guardCase("凭空加否定", "我要这个", "我不要这个", ok: false)
        guardCase("删口头语", "我觉得这个方案可以", "这个方案可以", ok: true)
        guardCase("改邮箱", "把文件发到 a@b.com", "把文件发到 c@d.com", ok: false)
        guardCase("改英文", "用 Swift 写", "用 Python 写", ok: false)
        guardCase("编造改动", "这个方案可以", "方案可以", edits: [.init(from: "不存在的内容", to: "")], ok: false)
        guardCase("正常改动", "嗯这个方案可以", "这个方案可以", edits: [.init(from: "嗯", to: "")], ok: true)

        // JSON 解析（模型可能包一层代码块）
        total += 1
        if ArkClient.parseRewrite("```json\n{\"text\":\"你好\",\"edits\":[]}\n```")?.text != "你好" {
            failures += 1
            print("✗ [JSON 解析] 代码块包着的 JSON 没解析出来")
        }

        // 长度策略
        let policy: [(LengthPolicy, String, String, Bool)] = [
            (.literal, "今天天气很好", "今天天汽很好", true),
            (.literal, String(repeating: "很长的一段话", count: 4), "今天", false),
            (.cleanup, "今天天气很好很好", "今天天气好", true),
            (.structured, "购物清单香蕉燕麦奶", "1. 香蕉\n2. 燕麦奶", true),
            (.structured, "购物清单香蕉燕麦奶", String(repeating: "很长", count: 40), false),
        ]
        for (name, original, output, expected) in policy {
            total += 1
            if name.accepts(output, original: original) != expected {
                failures += 1
                print("✗ [长度策略 \(name)] 原文 \(original.count) 字 → 结果 \(output.count) 字，期望 \(expected ? "接受" : "拒绝")")
            }
        }

        if failures == 0 {
            print("✓ 全部通过（\(total) 项）")
        } else {
            print("✗ \(failures)/\(total) 项失败")
        }
        return failures == 0
    }
}
