import AppKit

/// 排障用的小盒子：后台队列跑一遍、主线程取结果。
private final class ResultBox: @unchecked Sendable {
    var value = false
}


/// 等 ⌘C 把内容放上剪贴板；没变化（还是哨兵）说明没复制到东西。
private func waitForCopy(after sentinel: String) -> String? {
    for _ in 0..<12 {
        usleep(15_000)
        if let text = ClipboardLease.current, text != sentinel { return text }
    }
    return nil
}

@main
enum DaXiangShuoApp {
    /// `--probe-rewrite "…"`：验证改写链路（请求、SSE、校验），不启动界面。
    /// 地址/Key/模型可以用环境变量临时覆盖，避免为了排障去改用户的真实设置：
    /// `DAXIANGSHUO_PROBE_ENDPOINT` / `DAXIANGSHUO_PROBE_KEY` / `DAXIANGSHUO_PROBE_MODEL`。
    private static func probeRewrite(_ text: String) {
        let settings = AppSettings.shared
        let environment = ProcessInfo.processInfo.environment
        let config = ArkConfig(
            endpoint: environment["DAXIANGSHUO_PROBE_ENDPOINT"] ?? settings.arkConfig.endpoint,
            apiKey: environment["DAXIANGSHUO_PROBE_KEY"] ?? settings.arkConfig.apiKey,
            model: environment["DAXIANGSHUO_PROBE_MODEL"] ?? settings.arkConfig.model,
            temperature: settings.llmTemperature,
            sentenceTimeout: settings.llmSentenceTimeout,
            systemPrompt: ArkClient.defaultSystemPrompt,
            lengthGuard: settings.llmLengthGuard)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let rewrite = await ArkClient.shared.rewrite(text, glossary: [],
                                                         config: config,
                                                         timeout: settings.intentTimeout)
            if let rewrite {
                print("原文：\(text)")
                print("结果：\(rewrite.text)")
                print("改动：\(rewrite.edits.map { "\($0.from) → \($0.to)" }.joined(separator: "；"))")
            } else {
                print("没有通过校验或超时，保留原文：\(text)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            IconRenderer.exportIconset(to: args[i + 1])
            return
        }
        if args.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if args.contains("--probe-capsule") {
            // 排障用：看胶囊从窄到宽、长句裁头、以及「定稿中」的加载态。
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let capsule = VoiceCapsule()
            capsule.show(preview: true)
            for text in ["嗯那个什么", "嗯那个什么明天下午三点",
                         "嗯那个什么明天下午三点啊不对五点我们开个会",
                         "嗯那个什么明天下午三点啊不对五点我们开个会讨论一下这个季度的目标和预算到底怎么安排"] {
                capsule.setPreview(text)
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                print("长度 \(text.count) → 宽 \(capsule.debugFrame.width)")
            }
            capsule.showFinalizing("嗯那个什么明天下午三点啊不对五点我们开个会讨论一下这个季度的目标和预算到底怎么安排")
            print("定稿中 宽 \(capsule.debugFrame.width)")
            RunLoop.current.run(until: Date().addingTimeInterval(9))
            exit(0)
        }
        if args.contains("--dump-asr-request") {
            // 排障用：把识别首包的 JSON 打出来，确认热词、上下文真的带上了。
            if let i = args.firstIndex(of: "--context"), i + 1 < args.count {
                let lines = args[(i + 1)...].filter { !$0.hasPrefix("--") }
                let data = VolcProtocol.requestJSON(AppSettings.shared.asrOptions(hotwords: []), context: lines)
                print(String(data: data, encoding: .utf8) ?? "(编码失败)")
            } else {
                let words = PhraseStore.shared.hotwords
                let data = VolcProtocol.requestJSON(AppSettings.shared.asrOptions(hotwords: words))
                print(String(data: data, encoding: .utf8) ?? "(编码失败)")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-rewrite"), i + 1 < args.count {
            // 排障用：用当前设置里的纠错渠道跑一次整段意图改写，打印结果。
            probeRewrite(args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-line"), i + 2 < args.count {
            // 排障用：验证「整行一步替换」（Shift+Cmd+← → Cmd+C 比对 → Cmd+V）。
            // 用法：把光标放到某个输入框一行末尾，再跑
            //   DaXiangShuo --probe-line <typed> <replacement>
            let settle: Double = 3
            if args.contains("--with-app") {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                RunLoop.current.run(until: Date().addingTimeInterval(settle))
            } else {
                Thread.sleep(forTimeInterval: settle)
            }
            let before = ClipboardLease.current ?? "<空>"
            // --background：真正跑在打字线程（不是主线程）上再验一遍。
            var ok = false
            if args.contains("--background") {
                let box = ResultBox()
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInteractive).async {
                    box.value = LineReplacer.replaceLine(typed: args[i + 1], with: args[i + 2])
                    semaphore.signal()
                }
                semaphore.wait()
                ok = box.value
            } else {
                ok = LineReplacer.replaceLine(typed: args[i + 1], with: args[i + 2])
            }
            let after = ClipboardLease.current ?? "<空>"
            let report = "替换：\(ok ? "成功" : "失败")\n剪贴板前：\(before)\n剪贴板后：\(after)\n"
            print(report)
            try? report.write(toFile: "/tmp/dxs-probe-line.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-terminal"), i + 2 < args.count {
            // 排障用：验证终端里的「清行替换」（⌃E → ⌃U → 打字）。
            // 用法：把光标放到终端里待测的那一行，再跑
            //   DaXiangShuo --probe-terminal <打进去的字> <整理后的字> --type-first
            Thread.sleep(forTimeInterval: 3)
            if args.contains("--type-first") {
                KeyEmitter.shared.type(args[i + 1])
                usleep(200_000)
            }
            let ok = TerminalReplacer.replaceLine(with: args[i + 2])
            let report = "清行替换：\(ok ? "成功" : "失败")\n"
            print(report)
            try? report.write(toFile: "/tmp/dxs-probe-terminal.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if args.contains("--dump-ax") {
            // 排障用：看前台 App 到底有没有开无障碍树。
            Thread.sleep(forTimeInterval: 3)
            let report = FocusedFieldEditor.shared.dumpTree()
            print(report)
            try? report.write(toFile: "/tmp/dxs-dump-ax.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-ax"), i + 3 < args.count {            // 排障用：验证当前焦点输入框能不能用辅助功能接口一步替换文字。
            // 用法：把光标放到某个输入框末尾（内容以 expected 结尾），再跑
            //   DaXiangShuo --probe-ax <expected> <suffix> <replacement>
            let settle: Double = 3
            if args.contains("--with-app") {
                // 真身启动时是有 NSApplication 的；验证一下有 App 的时候系统级查询能不能用。
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                RunLoop.current.run(until: Date().addingTimeInterval(settle))
            } else {
                Thread.sleep(forTimeInterval: settle)
            }
            var report = "前：" + FocusedFieldEditor.shared.debugSnapshot() + "\n"
            // Chromium 系（Chrome/DingTalk/Lark/微信/Electron）默认不建完整无障碍树，
            // 要先把它打开才问得到焦点元素。试试两个开关到底有没有用。
            if args.contains("--manual-ax"), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let app = AXUIElementCreateApplication(pid)
                for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    let set = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
                    report += "开启 \(name)：\(set.rawValue)\n"
                    Thread.sleep(forTimeInterval: 0.8)
                    report += FocusedFieldEditor.shared.debugSnapshot() + "\n"
                }
            }
            let ok = FocusedFieldEditor.shared.replace(args[i + 1], keepingSuffix: args[i + 2],
                                                       with: args[i + 3])
            report += "替换：\(ok ? "成功" : "失败")\n"
            report += "后：" + FocusedFieldEditor.shared.debugSnapshot() + "\n"
            print(report)
            // 从 `open -n -a` 启动时看不到 stdout，所以再写一份到文件。
            try? report.write(toFile: "/tmp/dxs-probe-ax.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--pack-icns"), i + 3 < args.count {
            // --pack-icns <iconset> <基础 icns> <输出 icns>
            let ok = IconPacker.pack(iconset: args[i + 1], base: args[i + 2], output: args[i + 3])
            exit(ok ? 0 : 1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
