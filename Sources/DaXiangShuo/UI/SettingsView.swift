import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let dictation: DictationController
    let updates: UpdateService

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var micGranted = Permissions.microphoneGranted
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var inputStatus = AudioInput.current()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let accessibilityInfo = """
        用来响应全局快捷键，并把识别出的文字写进当前光标所在的输入框。

        开启方法：点「打开系统设置」→ 隐私与安全性 → 辅助功能，打开「大象说」的开关；列表里没有的话，点「+」添加大象说.app。授权后这里会自动变成「已授权」。

        重新打包安装后，需要在列表里把「大象说」先关掉再打开一次。
        """

    var body: some View {
        Page(scrolls: true) {
            SectionTitle("通用")
            Card {
                Row(title: "快捷键", info: "点击按钮后直接按下想用的键：可以单独按一个修饰键（如左 ⌥、右 ⌘、Fn），也可以按组合键（如 ⌃⌥Space）；不带修饰键的普通键只允许 F1～F20。按 Esc 取消录制。") {
                    HotkeyRecorder(hotkey: $settings.hotkey) { dictation.setHotkeysSuspended($0) }
                }
                CardDivider()
                Row(title: "触发方式", info: "长按说话：按住快捷键说话，松开结束。\n点按开始，再按结束：按一下开始说话，再按一下结束。") {
                    SelectMenu(options: HotkeyMode.allCases.map { ($0, $0.title) }, selection: $settings.hotkeyMode)
                }
                CardDivider()
                Row(title: "上屏方式", info: "「上屏」指把识别出的文字写进当前光标所在的输入框。\n\n实时逐字：边说边写，识别结果变化时原地修正。\n说完后一次性粘贴：说完后通过剪贴板一次粘贴进去。") {
                    SelectMenu(options: TypingMode.allCases.map { ($0, $0.title) }, selection: $settings.typingMode)
                }
                CardDivider()
                Row(title: "整段整理怎么落字", info: """
                    实时逐字模式下，整段意图改写会把已经写进去的字改成整理后的版本。

                    自动：能证明这一行只有刚打的字时，借剪贴板一步替换（几十个字也不会一个字一个字地退格）；证明不了就退回逐字退格。剪贴板用完立刻原样还回去，临时内容会标记成剪贴板管理器不记的类型。

                    只用按键：始终逐字退格再重打，完全不碰剪贴板。
                    """) {
                    SelectMenu(options: ReplaceMode.allCases.map { ($0, $0.title) }, selection: $settings.replaceMode)
                }
                CardDivider()
                Row(title: "终端里的整段整理", info: """
                    终端（Herdr、Otty、iTerm、Terminal…）没有「选中一块文字、粘贴覆盖」这回事。

                    直接清行替换（默认）：⌃U 一个键清空整行再打上去。只在一件事确定时才用：这一行从头到尾都是我们打的字（回车交出去之后、你没再自己敲过键）。判断不了就自动退回逐字退格。

                    只用按键：永远逐字退格再重打。

                    为什么不做「先读这一行再替换」：读内容得先发 ⌃A / ⇧End 把光标移过去，万一那个 App 不认 ⌃E，光标就回不来，接下来的退格会删到前面的字。
                    """) {
                    SelectMenu(options: TerminalReplaceMode.allCases.map { ($0, $0.title) }, selection: $settings.terminalReplace)
                }
                CardDivider()
                Row(title: "等纠错回来再落字", info: """
                    一句话说完、服务端定稿之后，先不上屏，等大模型纠错回来一次性写上。

                    好处：每句话在输入框里只写一次，不再「二遍识别闪一次、纠错再闪一次」，也不再边说边删。说话过程中正在说的那句会显示在屏幕下方的胶囊里，你照样看得见。代价是文字比你说话晚约 1 秒落进输入框。
                    """) {
                    Switch(isOn: $settings.paintAfterCorrection)
                }
                CardDivider()
                Row(title: "清理口头语", info: """
                    在本地（不联网）去掉三类语音噪音：

                    · 填充词：嗯、呃、唉、um、you know、「就是说…」
                    · 口吃：我我我觉得 → 我觉得；是是是 → 是
                    · 重复：这个这个、我觉得我觉得

                    只删不改成，遇到拿不准的地方（比如「那个产品」里的「那个」）保持原样。语义层面的自我修正（「三点…啊不对五点」）需要开启整段意图改写。
                    """) {
                    Switch(isOn: $settings.cleanFillers)
                }
                CardDivider()
                Row(title: "登录时自动启动", info: launchError) {
                    Switch(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                }
                CardDivider()
                Row(title: "版本", info: """
                    打开应用时自动检查一次新版本，之后每小时检查一次。发现新版本会自动在后台下载好，点「更新到 x.y.z」后才替换当前版本并重启。

                    更新包会先校验 SHA-256，确认是我们发布的文件才安装；替换过程中如果出错，会自动保留原来的版本。
                    """) {
                    versionControl
                }
            }

            SectionTitle("权限")
            Card {
                Row(title: "麦克风", info: "用来收听你说的话。") {
                    StatusBadge(text: micGranted ? "已授权" : "未授权", ok: micGranted)
                    if !micGranted {
                        Button(Permissions.microphoneDenied ? "打开系统设置" : "授权") {
                            if Permissions.microphoneDenied {
                                Permissions.openMicrophoneSettings()
                            } else {
                                Permissions.requestMicrophoneIfNeeded { micGranted = $0 }
                            }
                        }
                        .buttonStyle(.soft)
                    }
                }
                CardDivider()
                Row(title: "输入设备", info: inputInfo) {
                    StatusBadge(text: inputStatus.isReady ? "已连接" : "未检测到",
                                ok: inputStatus.isReady)
                    if !inputStatus.isReady {
                        Button("打开声音设置") { Permissions.openSoundSettings() }.buttonStyle(.soft)
                    }
                }
                CardDivider()
                Row(title: "辅助功能", info: Self.accessibilityInfo) {
                    StatusBadge(text: axGranted ? "已授权" : "未授权", ok: axGranted)
                    if !axGranted {
                        Button("打开系统设置") { Permissions.openAccessibilitySettings() }.buttonStyle(.soft)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            micGranted = Permissions.microphoneGranted
            axGranted = Permissions.accessibilityGranted
            inputStatus = AudioInput.current()
        }
    }

    private var inputInfo: String {
        switch inputStatus {
        case .ready(let device):
            "系统当前使用的声音输入设备：\(device.name)（\(device.channels) 声道）。插拔麦克风后会自动更新，不需要重启。"
        case .noDevice:
            "没有检测到任何输入设备。请插上麦克风（或用带麦克风的耳机），状态会自动更新；也可以用「打开声音设置」看一下系统里的输入设备列表。"
        case .noChannels(let device):
            "「\(device.name)」没有可用的输入声道，请换一个输入设备。"
        }
    }

    /// 版本这一行的右侧：当前版本 + 检查状态 + 手动检查按钮。
    /// 升级按钮只放在主界面右上角，这里不重复出现。
    private var versionControl: some View {
        HStack(spacing: 8) {
            Text("v\(updates.currentVersion)")
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
            Text(updateStatus).foregroundStyle(updateStatusColor)
            Button("检查更新") { Task { await updates.check(manual: true) } }
                .buttonStyle(.soft)
                .disabled(updates.isBusy)
        }
    }

    private var updateStatus: String {
        switch updates.state {
        case .idle: ""
        case .checking: "正在检查…"
        case .upToDate: "已是最新"
        case .downloading: updates.release.map { "正在下载 \($0.version)…" } ?? "正在下载…"
        case .ready: updates.release.map { "有新版本 \($0.version)，点左下角「升级」" } ?? "有新版本"
        case .installing: "正在安装…"
        case .failed(let message): message
        }
    }

    private var updateStatusColor: Color {
        if case .failed = updates.state { return Theme.warning }
        return Theme.secondary
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "设置失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
struct ModelSettingsView: View {
    @Bindable var settings: AppSettings
    let dictation: DictationController

    enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }

    @State private var asrTest: TestState = .idle
    @State private var arkTest: TestState = .idle

    var body: some View {
        Page(scrolls: true) {
            SectionTitle(text: "语音识别", info: "两个渠道都能用，点上面的卡片切换，另一套参数会原样保留。") {
                testControl(asrTest, action: testASR)
            }
            ProviderPicker(options: asrProviders, selection: $settings.asrEngine)
                .padding(.bottom, 10)
            Card {
                ChannelHeader(title: settings.asrEngine.title,
                              detail: settings.asrEngine.detail,
                              tint: settings.asrEngine == .volcengine ? Theme.volcengine : Theme.deepseek)
                if settings.asrEngine == .volcengine {
                    volcengineASR
                } else {
                    deepseekASR
                }
            }

            SectionTitle(text: "大模型纠错", info: "纠错用哪个渠道和语音识别无关，可以任意交叉组合。") {
                testControl(arkTest, action: testArk)
            }
            ProviderPicker(options: llmProviders, selection: $settings.llmEngine)
                .padding(.bottom, 10)
            Card {
                ChannelHeader(title: llmTitle,
                              detail: llmDetail,
                              tint: settings.llmEngine == .ark ? Theme.volcengine : Theme.deepseek)
                CardDivider()
                Row(title: "逐句纠错", info: "每句话确定后，用大模型纠正错字、同音字和语法。完全异步，不会拖慢上屏；超过「单句等待上限」还没返回就保留识别原文。") {
                    Switch(isOn: $settings.llmEnabled)
                }
                if settings.llmEngine == .ark {
                    arkLLM
                } else {
                    deepseekLLM
                }
                CardDivider()
                Row(title: "温度", info: "采样温度，0–2。纠错只需要稳定改写，建议 0；调高会更「自由」，也更容易改写你的原话。两个渠道共用。") {
                    DoubleField(value: $settings.llmTemperature, range: 0...2, width: 76)
                }
                CardDivider()
                Row(title: "单句等待上限", info: "一句话最多等多久（秒，0.3–10）。超时就先显示识别原文，之后也不会再补。调大更准但可能拖慢定稿。") {
                    DoubleField(value: $settings.llmSentenceTimeout, range: 0.3...10, suffix: "秒", width: 76)
                }
                CardDivider()
                Row(title: "上文句数", info: "纠错时往上带几句已经确定的句子，帮模型理解语境（0–6）。0 表示只看当前句。") {
                    IntField(value: $settings.llmContextSentences, range: 0...6, suffix: "句", width: 76)
                }
                CardDivider()
                Row(title: "结果长度校验", info: "模型偶尔会答非所问（比如把话续写下去）。开启后，纠正结果与原文长度差太多就丢弃，保留识别原文。") {
                    Switch(isOn: $settings.llmLengthGuard)
                }
                CardDivider()
                promptEditor
            }

            SectionTitle("意图改写", info: """
                说完之后，把整段话交给大模型再整理一遍：去掉口头噪音、合并「三点……啊不对五点」这类改口，只保留你最终想说的内容。

                松开快捷键就立刻开跑，正常一句大约 1 秒出结果；超时、失败或结果不可信时会自动保留识别原文，不会卡住你。用户中途自己打字或点了鼠标就不做改写。

                DeepSeek 这类带思考（推理）的模型会自动关闭思考模式：不做这一步，同一个请求要等 2–5 秒。
                """)
            Card {
                Row(title: "整段意图改写", info: "关掉后只做逐句纠错和本地口头语清理。") {
                    Switch(isOn: $settings.intentRewrite)
                }
                CardDivider()
                Row(title: "等待上限", info: "最多等多久（秒，0.3–5）。超时就先上屏识别原文；调大更准但更慢。") {
                    DoubleField(value: $settings.intentTimeout, range: 0.3...5, suffix: "秒", width: 76)
                }
                CardDivider()
                Row(title: "使用渠道", info: "和上面的纠错共用一个渠道与 API Key。") {
                    StatusBadge(text: settings.llmEngine == .ark ? "火山方舟 · \(llmDetail)" : "DeepSeek · \(llmDetail)",
                                ok: settings.arkConfig.isComplete, neutral: settings.arkConfig.isComplete)
                }
            }

            SectionTitle("参数")
            Card {
                Row(title: "恢复默认参数", info: "把两个渠道的所有参数恢复成出厂值，API Key 和当前选择的渠道都不动。") {
                    Button("恢复默认") {
                        settings.resetModelParameters()
                        asrTest = .idle
                        arkTest = .idle
                    }
                    .buttonStyle(.soft)
                }
            }
        }
    }

    // MARK: 渠道

    private var asrProviders: [ProviderOption<ASREngine>] {
        [
            ProviderOption(value: .volcengine, title: "火山引擎",
                           subtitle: "双向流式 · 边说边出字",
                           symbol: "flame.fill", tint: Theme.volcengine),
            ProviderOption(value: .deepseek, title: "DeepSeek",
                           subtitle: "整段上传 · 说完一次出字",
                           symbol: "sparkles", tint: Theme.deepseek),
        ]
    }

    private var llmProviders: [ProviderOption<LLMEngine>] {
        [
            ProviderOption(value: .ark, title: "火山方舟",
                           subtitle: trimmed(settings.arkModel, or: AppSettings.defaultArkModel),
                           symbol: "flame.fill", tint: Theme.volcengine),
            ProviderOption(value: .deepseek, title: "DeepSeek",
                           subtitle: trimmed(settings.deepseekLLMModel, or: AppSettings.defaultDeepSeekLLMModel),
                           symbol: "sparkles", tint: Theme.deepseek),
        ]
    }

    private var llmTitle: String {
        settings.llmEngine == .ark ? "火山方舟" : "DeepSeek"
    }

    private var llmDetail: String {
        settings.llmEngine == .ark
            ? trimmed(settings.arkModel, or: AppSettings.defaultArkModel)
            : trimmed(settings.deepseekLLMModel, or: AppSettings.defaultDeepSeekLLMModel)
    }

    private func trimmed(_ value: String, or fallback: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    // MARK: 语音识别

    @ViewBuilder
    private var volcengineASR: some View {
        CardDivider()
        Row(title: "API Key",
            link: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")) {
            KeyField(text: $settings.asrAPIKey)
        }
        CardDivider()
        Row(title: "接口地址", info: "火山引擎双向流式语音识别的 WebSocket 地址（以 wss:// 开头）。一般不用改。") {
            WideField(text: $settings.asrEndpoint, placeholder: AppSettings.defaultASREndpoint)
        }
        CardDivider()
        Row(title: "资源 ID", info: "控制台里对应资源的 Resource ID，决定按哪种方式计费。\n\n按小时计费：volc.seedasr.sauc.duration\n并发版：volc.bigasr.sauc.concurrent") {
            WideField(text: $settings.asrResourceID, placeholder: AppSettings.defaultASRResourceID)
        }
        CardDivider()
        Row(title: "模型名称", info: "请求里的 model_name，当前流式识别只有 bigmodel 一个取值。") {
            WideField(text: $settings.asrModel, placeholder: AppSettings.defaultASRModel)
        }
        CardDivider()
        Row(title: "二遍识别", info: "每句话结束后，用非流式模型再识别一遍并原地修正，更准确，但定稿会稍慢。") {
            Switch(isOn: $settings.asrNonstream)
        }
        CardDivider()
        Row(title: "数字与单位规范化", info: "开启后「一百二十三」会写成「123」，「两公斤」会写成「2 公斤」。对应请求参数 enable_itn。") {
            Switch(isOn: $settings.asrITN)
        }
        CardDivider()
        Row(title: "自动标点", info: "自动补逗号、句号、问号。对应请求参数 enable_punc。") {
            Switch(isOn: $settings.asrPunc)
        }
        CardDivider()
        Row(title: "顺滑（去口水词）", info: "去掉「嗯、那个、就是说」这类口头语。对应请求参数 enable_ddc。\n\n打开后识别结果更干净，但会改写原话。") {
            Switch(isOn: $settings.asrDDC)
        }
        CardDivider()
        Row(title: "结果类型", info: "完整结果：每个包都给从头到尾的全文，边说边改，推荐。\n仅最新一句：只返回最新那句，适合自己拼接。\n\n对应请求参数 result_type。") {
            SelectMenu(options: ASRResultType.allCases.map { ($0, $0.title) },
                       selection: $settings.asrResultType)
        }
        CardDivider()
        Row(title: "停顿判定", info: "说完一句话后停顿多久算这句话结束（毫秒，200–3000）。调小更跟手但容易把一句话断开，调大更稳但定稿更慢。对应请求参数 end_window_size。") {
            IntField(value: $settings.asrEndWindowMs, range: 200...3000, suffix: "ms", width: 76)
        }
        CardDivider()
        Row(title: "音频包时长", info: "每次发给服务器的音频长度（毫秒，40–200）。越小越实时、请求越密；越大越省流量、延迟越高。") {
            IntField(value: $settings.asrChunkMs, range: 40...200, suffix: "ms", width: 76)
        }
        CardDivider()
        Row(title: "强制断句", info: "一句话最长说多久就被强制结束（毫秒），0 表示交给服务端默认。对应请求参数 force_to_speech_time。") {
            IntField(value: $settings.asrForceToSpeechMs, range: 0...60000, suffix: "ms", width: 76)
        }
        CardDivider()
        Row(title: "把最近几句当上下文", info: """
            把最近三句已经上屏的正文一起发给识别服务，帮模型提前知道你会用到哪些词（尤其是 API、DeepSeek、OpenWrt 这类穿插在中文里的英文术语）。

            官方文档说上下文在「二遍识别」链路里效果最好，但会把你最近几句文字也传到识别服务（以前只传音频），所以默认不开。

            对应请求参数 corpus.context 里的 context_type/context_data。
            """) {
            Switch(isOn: $settings.asrContext)
        }
    }

    @ViewBuilder
    private var deepseekASR: some View {
        CardDivider()
        Row(title: "API Key",
            link: URL(string: "https://platform.deepseek.com/api_keys")) {
            KeyField(text: $settings.deepseekAPIKey)
        }
        CardDivider()
        Row(title: "接口地址", info: "DeepSeek 的语音识别接口，POST 一次发送整段音频。") {
            WideField(text: $settings.deepseekASREndpoint, placeholder: AppSettings.defaultDeepSeekASREndpoint)
        }
        CardDivider()
        Row(title: "识别方式", info: """
            DeepSeek 是整段上传：录完才把整段音频发过去，返回整段文字，没有流式结果。

            所以选了这个渠道就相当于「说完后一次性上屏」，通用设置里的「实时逐字上屏」对它不生效；单次最长 120 秒、8 MB，超出会提示。
            """) {
            StatusBadge(text: "整段上传 · 最长 120 秒", ok: true, neutral: true)
        }
        CardDivider()
        Row(title: "与纠错共用 Key", info: "DeepSeek 的语音识别和大模型纠错用的是同一个 API Key，填一次即可。") {
            StatusBadge(text: settings.deepseekAPIKey.isEmpty ? "尚未填写" : "已填写",
                        ok: !settings.deepseekAPIKey.isEmpty)
        }
    }

    // MARK: 大模型纠错

    @ViewBuilder
    private var arkLLM: some View {
        CardDivider()
        Row(title: "API Key",
            link: URL(string: "https://ark.volcengine.com/region:cn-beijing/apiKey")) {
            KeyField(text: $settings.arkAPIKey)
        }
        CardDivider()
        Row(title: "接口地址", info: "OpenAI 兼容的对话接口地址，默认是火山方舟北京区。") {
            WideField(text: $settings.arkEndpoint, placeholder: AppSettings.defaultArkEndpoint)
        }
        CardDivider()
        Row(title: "模型名称", info: "方舟的模型 ID（如 deepseek-v4-1-flash-260910），或你自己创建的推理接入点 ID（ep- 开头）。留空则使用默认值。\n\n纠错要求快，建议选带 flash / mini 的轻量模型。") {
            ModelField(text: $settings.arkModel, placeholder: AppSettings.defaultArkModel)
        }
    }

    @ViewBuilder
    private var deepseekLLM: some View {
        CardDivider()
        Row(title: "API Key",
            link: URL(string: "https://platform.deepseek.com/api_keys")) {
            KeyField(text: $settings.deepseekAPIKey)
        }
        CardDivider()
        Row(title: "接口地址", info: "DeepSeek 的 OpenAI 兼容对话接口。") {
            WideField(text: $settings.deepseekLLMEndpoint, placeholder: AppSettings.defaultDeepSeekLLMEndpoint)
        }
        CardDivider()
        Row(title: "模型名称", info: "deepseek-chat（通用对话，快）或 deepseek-reasoner（推理模型，更慢但更懂语境）。\n\n纠错只要求快和稳，一般用 deepseek-chat。") {
            WideField(text: $settings.deepseekLLMModel, placeholder: AppSettings.defaultDeepSeekLLMModel)
        }
    }

    /// 提示词编辑器：整行铺开，方便看清规则。留空等于用内置的那一份。
    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("提示词")
                InfoTip(text: """
                    发给大模型的系统提示词，两个渠道共用。内置的这份只做「错别字/同音字/标点」的最小改动，并要求只输出正文。

                    可以按自己的习惯改，比如规定「输出简体中文」「专业术语按词典写法」「口语要不要转书面语」。留空并保存则回到内置提示词。

                    词典里的热词会自动追加到这段提示词后面，不需要自己写进来。
                    """)
                Spacer()
                if !settings.llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("恢复内置") { settings.llmPrompt = "" }.buttonStyle(.soft)
                }
                Button("查看内置") { settings.llmPrompt = ArkClient.defaultSystemPrompt }.buttonStyle(.soft)
            }
            TextEditor(text: Binding(
                get: { settings.llmPrompt.isEmpty ? ArkClient.defaultSystemPrompt : settings.llmPrompt },
                set: { settings.llmPrompt = $0 == ArkClient.defaultSystemPrompt ? "" : $0 }
            ))
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 132)
            .background(Theme.controlShape().fill(Theme.control)
                .shadow(color: Theme.controlShadow, radius: 1.2, y: 0.5))
            .overlay(Theme.controlShape().strokeBorder(Theme.border, lineWidth: Theme.hairline))
        }
        .font(Theme.font)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 放在区域标题右侧：测试结果 + 「测试连接」按钮。成功只显示「连接成功」。
    private func testControl(_ state: TestState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .ok:
                StatusBadge(text: "连接成功", ok: true)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            Button("测试连接", action: action)
                .buttonStyle(.soft)
                .disabled(state == .running)
        }
        .font(Theme.font)
    }

    private func testASR() {
        switch settings.asrEngine {
        case .volcengine:
            let config = settings.asrConfig
            guard config.isComplete else {
                asrTest = .failed("请先填写 API Key 和资源 ID")
                return
            }
            asrTest = .running
            let json = dictation.requestJSON
            Task {
                let result = await ASRTester.run(config: config, requestJSON: json)
                asrTest = result.ok ? .ok(result.message) : .failed(result.message)
            }
        case .deepseek:
            let config = settings.deepseekASRConfig
            guard config.isComplete else {
                asrTest = .failed("请先填写 DeepSeek 的 API Key")
                return
            }
            asrTest = .running
            Task {
                let result = await DeepSeekASRTester.run(config: config)
                asrTest = result.ok ? .ok(result.message) : .failed(result.message)
            }
        }
    }

    private func testArk() {
        let config = settings.arkConfig
        guard config.isComplete else {
            arkTest = .failed("请先填写 API Key")
            return
        }
        arkTest = .running
        Task {
            let result = await ArkClient.shared.test(config)
            arkTest = result.ok ? .ok(result.message) : .failed(result.message)
        }
    }
}

/// 模型名称输入框：留空时显示默认值作为占位提示。
struct ModelField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .fieldStyle()
            .frame(width: Theme.keyFieldWidth)
    }
}

/// 宽输入框：接口地址、资源 ID、模型名称这类长文本。
struct WideField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .fieldStyle()
            .frame(width: 330)
    }
}

/// 整数参数输入框，右侧可以带单位，超范围自动夹紧。
struct IntField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String?
    var width: CGFloat = 76

    var body: some View {
        HStack(spacing: 5) {
            TextField("", value: Binding(get: { value },
                                         set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .fieldStyle()
                .frame(width: width)
            if let suffix {
                Text(suffix).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// 小数参数输入框（温度、秒数），超范围自动夹紧。
struct DoubleField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix: String?
    var width: CGFloat = 76

    var body: some View {
        HStack(spacing: 5) {
            TextField("", value: Binding(get: { value },
                                         set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .fieldStyle()
                .frame(width: width)
            if let suffix {
                Text(suffix).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// 密钥输入框：可以 ⌘V 粘贴，也可以点「粘贴」按钮；点眼睛切换明文显示。
struct KeyField: View {
    @Binding var text: String
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 4) {
            ClearButton { text = "" }
                .opacity(text.isEmpty ? 0 : 1)
                .disabled(text.isEmpty)
            Group {
                if reveal {
                    TextField("API Key", text: $text, prompt: Text("粘贴或输入"))
                } else {
                    SecureField("API Key", text: $text, prompt: Text("粘贴或输入"))
                }
            }
            .labelsHidden()
            .fieldStyle()
            .frame(width: Theme.keyFieldWidth)

            IconButton(systemName: reveal ? "eye.slash" : "eye", help: reveal ? "隐藏" : "显示") { reveal.toggle() }
            Button("粘贴") {
                if let value = NSPasteboard.general.string(forType: .string) {
                    text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .buttonStyle(.soft)
        }
        .fixedSize()
    }
}

/// 录制快捷键的按钮。录制期间暂停全局快捷键，免得按下旧快捷键就开始听写。
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?
    @State private var capture = HotkeyCapture()

    var body: some View {
        HStack(spacing: 4) {
            ClearButton { hotkey = nil }
                .opacity(hotkey == nil || recording ? 0 : 1)
                .disabled(hotkey == nil || recording)
            Button(recording ? "请按下快捷键…" : (hotkey?.display ?? "点击录制")) {
                recording ? stop() : start()
            }
            .buttonStyle(.soft)
            .overlay(Theme.controlShape()
                .strokeBorder(recording ? Theme.accent : .clear, lineWidth: 1))
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        capture = HotkeyCapture()
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch capture.handle(event) {
            case .pending:
                break
            case .cancelled:
                stop()
            case .rejected:
                NSSound.beep()
            case .recorded(let value):
                hotkey = value
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChange(false)
    }
}

/// 录制状态机：单独按下再松开一个修饰键，得到修饰键快捷键；按下组合键，得到组合快捷键。
struct HotkeyCapture {
    enum Outcome: Equatable {
        case pending, cancelled, rejected
        case recorded(Hotkey)
    }

    private var pendingModifier: Int64?

    mutating func handle(_ event: NSEvent) -> Outcome {
        switch event.type {
        case .flagsChanged:
            let code = Int64(event.keyCode)
            guard let info = Hotkey.modifierKeys[code] else { return .pending }
            let down = UInt64(event.modifierFlags.rawValue) & info.mask != 0
            if down {
                if pendingModifier == nil { pendingModifier = code }
            } else if pendingModifier == code, let hotkey = Hotkey.modifier(keyCode: code) {
                return .recorded(hotkey)
            }
            return .pending
        case .keyDown:
            pendingModifier = nil
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty { return .cancelled }
            guard !flags.isEmpty || Self.functionKeys[event.keyCode] != nil else { return .rejected }
            return .recorded(Hotkey(kind: .combo, keyCode: Int64(event.keyCode), flags: UInt64(flags.rawValue),
                                    display: Self.describe(flags: flags, event: event)))
        default:
            return .pending
        }
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]
    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
    ]

    private static func describe(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key = functionKeys[event.keyCode] ?? namedKeys[event.keyCode]
            ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return text + key
    }
}

