import CoreGraphics
import Foundation
import LocalAuthentication
import Observation
import Security

enum TypingMode: String, CaseIterable, Identifiable {
    case live, paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "实时逐字上屏"
        case .paste: "说完后一次性粘贴"
        }
    }
}

/// 终端里整段整理怎么落字（终端没有「选中即替换」，得靠行编辑命令）。
enum TerminalReplaceMode: String, CaseIterable, Identifiable {
    /// ⌃U 一个键清空整行再打上去：快，但会把这一行原有的内容一起清掉。
    case direct
    /// 永远逐字退格。终端里发按键去「读这一行」会移动光标，风险太大，所以默认这条。
    case keysOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "直接清行替换（快）"
        case .keysOnly: "只用按键"
        }
    }
}

/// 整段整理的落字方式。
enum ReplaceMode: String, CaseIterable, Identifiable {
    /// 能证明这一行只有我们打的字时，借剪贴板一步替换；否则退回逐字退格。
    case automatic
    /// 永远逐字退格 + 重打。
    case keysOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动（能一步替换）"
        case .keysOnly: "只用按键"
        }
    }
}

/// 录制得到的快捷键：单独一个修饰键（如右 ⌥），或者「修饰键 + 普通键」的组合。
struct Hotkey: Codable, Equatable {
    enum Kind: String, Codable {
        case modifier, combo
    }

    var kind: Kind
    var keyCode: Int64
    /// modifier：区分左右的设备标志位；combo：⌘ ⌥ ⌃ ⇧ 的组合。
    var flags: UInt64
    var display: String

    static let comboMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    /// 修饰键的 keyCode 到设备标志位（NX_DEVICE*KEYMASK）和显示名。
    static let modifierKeys: [Int64: (mask: UInt64, name: String)] = [
        54: (0x10, "右 ⌘ Command"), 55: (0x08, "左 ⌘ Command"),
        58: (0x20, "左 ⌥ Option"), 61: (0x40, "右 ⌥ Option"),
        59: (0x01, "左 ⌃ Control"), 62: (0x2000, "右 ⌃ Control"),
        56: (0x02, "左 ⇧ Shift"), 60: (0x04, "右 ⇧ Shift"),
        63: (CGEventFlags.maskSecondaryFn.rawValue, "Fn / 🌐"),
    ]

    static func modifier(keyCode: Int64) -> Hotkey? {
        guard let info = modifierKeys[keyCode] else { return nil }
        return Hotkey(kind: .modifier, keyCode: keyCode, flags: info.mask, display: info.name)
    }

    static let defaultHotkey = Hotkey.modifier(keyCode: 58)!
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    /// 按住开始说话，松开结束。
    case hold
    /// 点按一下开始，再点按一下结束。
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "长按说话"
        case .toggle: "点按开始，再按结束"
        }
    }
}

/// 语音识别渠道。
enum ASREngine: String, CaseIterable, Identifiable {
    /// 火山引擎双向流式识别：边说边出字。
    case volcengine
    /// DeepSeek：整段上传，说完才有结果。
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volcengine: "火山引擎"
        case .deepseek: "DeepSeek"
        }
    }

    var detail: String {
        switch self {
        case .volcengine: "双向流式，边说边出字，停顿 0.6 秒定稿"
        case .deepseek: "整段上传，说完一次性出字（单次最长 120 秒）"
        }
    }
}

/// 大模型纠错渠道。
enum LLMEngine: String, CaseIterable, Identifiable {
    case ark
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ark: "火山方舟"
        case .deepseek: "DeepSeek"
        }
    }
}

/// 语音识别的结果类型：完整结果（每包都是从头到尾的全文）或只有最新一句。
enum ASRResultType: String, CaseIterable, Identifiable {
    case full, single

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "完整结果"
        case .single: "仅最新一句"
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    // 下面是各项参数的默认值。除了 API Key，其它都能在「模型设置」里改。
    static let defaultASREndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static let defaultASRResourceID = "volc.seedasr.sauc.duration"
    static let defaultASRModel = "bigmodel"
    static let defaultArkEndpoint = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    static let defaultArkModel = "deepseek-v4-1-flash-260910"
    static let defaultDeepSeekASREndpoint = "https://api.deepseek.com/v1/tools/asr"
    static let defaultDeepSeekLLMEndpoint = "https://api.deepseek.com/chat/completions"
    static let defaultDeepSeekLLMModel = "deepseek-flash"
    /// 每个音频包 100ms，停顿 600ms 判定一句话结束。
    static let defaultChunkMs = 100
    static let defaultEndWindowMs = 600
    /// 单句纠错的等待上限默认值（秒）。带思考的模型关掉思考后一句大约 0.7–1 秒，
    /// 0.5 秒会让每句纠错都超时，等于没开。
    static let defaultSentenceTimeout: Double = 1.5

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// @Observable 的 didSet 在 init 里也会触发，加载完成前不做持久化和回调。
    @ObservationIgnored private var loaded = false
    @ObservationIgnored var onASRConfigChange: (() -> Void)?
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    // MARK: 渠道选择

    /// 用哪个渠道做语音识别；大模型纠错单独选，两者可以交叉。
    var asrEngine: ASREngine { didSet { store(asrEngine.rawValue, "asrEngine"); asrChanged() } }
    var llmEngine: LLMEngine { didSet { store(llmEngine.rawValue, "llmEngine") } }

    // MARK: 语音识别（新版控制台，只需要 API Key）

    var asrAPIKey: String { didSet { store(asrAPIKey, "asrAPIKey"); asrChanged() } }
    var asrEndpoint: String { didSet { store(asrEndpoint, "asrEndpoint"); asrChanged() } }
    var asrResourceID: String { didSet { store(asrResourceID, "asrResourceID"); asrChanged() } }
    var asrModel: String { didSet { store(asrModel, "asrModel"); asrChanged() } }
    /// 二遍识别：每句话结束后用非流式模型再识别一遍。
    var asrNonstream: Bool { didSet { store(asrNonstream, "asrNonstream"); asrChanged() } }
    /// 数字与单位规范化（“一百二十三” → “123”）。
    var asrITN: Bool { didSet { store(asrITN, "asrITN"); asrChanged() } }
    /// 自动加标点。
    var asrPunc: Bool { didSet { store(asrPunc, "asrPunc"); asrChanged() } }
    /// 顺滑：去掉“嗯、那个”这类口水词。
    var asrDDC: Bool { didSet { store(asrDDC, "asrDDC"); asrChanged() } }
    var asrResultType: ASRResultType { didSet { store(asrResultType.rawValue, "asrResultType"); asrChanged() } }
    /// 停顿多久算一句话结束（毫秒）。
    var asrEndWindowMs: Int { didSet { store(asrEndWindowMs, "asrEndWindowMs"); asrChanged() } }
    /// 每个音频包多长（毫秒），越小越实时，越大越省流量。
    var asrChunkMs: Int { didSet { store(asrChunkMs, "asrChunkMs"); asrChanged() } }
    /// 一句话最长多久就被强制断句（毫秒），0 表示交给服务端默认。
    var asrForceToSpeechMs: Int { didSet { store(asrForceToSpeechMs, "asrForceToSpeechMs"); asrChanged() } }
    /// 把最近几句上屏的文本当上下文发给识别服务（提升专有名词/英文术语命中，但会多传文字）。
    var asrContext: Bool { didSet { store(asrContext, "asrContext") } }

    // MARK: DeepSeek（语音识别与大模型纠错共用一个 Key）

    /// DeepSeek 的 API Key，识别和纠错共用。
    var deepseekAPIKey: String { didSet { store(deepseekAPIKey, "deepseekAPIKey"); asrChanged() } }
    var deepseekASREndpoint: String { didSet { store(deepseekASREndpoint, "deepseekASREndpoint"); asrChanged() } }
    var deepseekLLMEndpoint: String { didSet { store(deepseekLLMEndpoint, "deepseekLLMEndpoint") } }
    var deepseekLLMModel: String { didSet { store(deepseekLLMModel, "deepseekLLMModel") } }

    // MARK: 大模型纠错（两个渠道共用下面这些参数）

    var llmEnabled: Bool { didSet { store(llmEnabled, "llmEnabled") } }
    var arkEndpoint: String { didSet { store(arkEndpoint, "arkEndpoint") } }
    var arkAPIKey: String { didSet { store(arkAPIKey, "arkAPIKey") } }
    /// 纠错用的大模型名称（方舟的模型 ID 或接入点 ID）；留空时使用默认值。
    var arkModel: String { didSet { store(arkModel, "arkModel") } }
    /// 采样温度，0 最稳定。
    var llmTemperature: Double { didSet { store(llmTemperature, "llmTemperature") } }
    /// 单句纠错的等待上限（秒），超时就保留识别原文。
    var llmSentenceTimeout: Double { didSet { store(llmSentenceTimeout, "llmSentenceTimeout") } }
    /// 纠错时往上带几句上文。
    var llmContextSentences: Int { didSet { store(llmContextSentences, "llmContextSentences") } }
    /// 结果与原文长度差太多就丢弃，避免模型答非所问。
    var llmLengthGuard: Bool { didSet { store(llmLengthGuard, "llmLengthGuard") } }
    /// 松键后整段意图改写（合并改口、去掉口头噪音）。
    var intentRewrite: Bool { didSet { store(intentRewrite, "intentRewrite") } }
    /// 整段意图改写的等待上限（秒）。
    var intentTimeout: Double { didSet { store(intentTimeout, "intentTimeout") } }
    /// 纠错用的系统提示词；留空时使用内置的那一份。
    var llmPrompt: String { didSet { store(llmPrompt, "llmPrompt") } }

    // MARK: 上屏与快捷键

    var typingMode: TypingMode { didSet { store(typingMode.rawValue, "typingMode") } }
    /// 整段整理的落字方式。
    var replaceMode: ReplaceMode { didSet { store(replaceMode.rawValue, "replaceMode") } }
    /// 终端（Herdr / Otty / iTerm…）里整段整理怎么落字。
    var terminalReplace: TerminalReplaceMode { didSet { store(terminalReplace.rawValue, "terminalReplace") } }
    /// 等纠错回来再落字：一句话定稿后先不上屏，等大模型纠错回来一次写上，
    /// 不再「二遍识别闪一次、纠错再闪一次」。
    var paintAfterCorrection: Bool { didSet { store(paintAfterCorrection, "paintAfterCorrection") } }
    /// 本地清理口头语（填充词、口吃、重复）。默认开。
    var cleanFillers: Bool { didSet { store(cleanFillers, "cleanFillers") } }
    var hotkey: Hotkey? { didSet { storeHotkey(hotkey, "hotkey") } }
    var hotkeyMode: HotkeyMode {
        didSet { store(hotkeyMode.rawValue, "hotkeyMode"); if loaded { onHotkeyChange?() } }
    }

    private init() {
        let d = UserDefaults.standard
        asrEngine = ASREngine(rawValue: d.string(forKey: "asrEngine") ?? "") ?? .volcengine
        llmEngine = LLMEngine(rawValue: d.string(forKey: "llmEngine") ?? "") ?? .deepseek
        deepseekAPIKey = Self.storedSecret("deepseekAPIKey", defaults: d)
        deepseekASREndpoint = d.string(forKey: "deepseekASREndpoint") ?? Self.defaultDeepSeekASREndpoint
        deepseekLLMEndpoint = d.string(forKey: "deepseekLLMEndpoint") ?? Self.defaultDeepSeekLLMEndpoint
        deepseekLLMModel = d.string(forKey: "deepseekLLMModel") ?? Self.defaultDeepSeekLLMModel
        asrAPIKey = Self.storedSecret("asrAPIKey", defaults: d)
        asrEndpoint = d.string(forKey: "asrEndpoint") ?? Self.defaultASREndpoint
        asrResourceID = d.string(forKey: "asrResourceID") ?? Self.defaultASRResourceID
        asrModel = d.string(forKey: "asrModel") ?? Self.defaultASRModel
        asrNonstream = d.object(forKey: "asrNonstream") as? Bool ?? true
        asrITN = d.object(forKey: "asrITN") as? Bool ?? true
        asrPunc = d.object(forKey: "asrPunc") as? Bool ?? true
        asrDDC = d.object(forKey: "asrDDC") as? Bool ?? true
        asrResultType = ASRResultType(rawValue: d.string(forKey: "asrResultType") ?? "") ?? .full
        asrEndWindowMs = Self.storedInt(d, "asrEndWindowMs") ?? Self.defaultEndWindowMs
        asrChunkMs = Self.storedInt(d, "asrChunkMs") ?? Self.defaultChunkMs
        asrForceToSpeechMs = Self.storedInt(d, "asrForceToSpeechMs") ?? 0
        asrContext = d.object(forKey: "asrContext") as? Bool ?? false
        llmEnabled = d.object(forKey: "llmEnabled") as? Bool ?? true
        arkEndpoint = d.string(forKey: "arkEndpoint") ?? Self.defaultArkEndpoint
        arkAPIKey = Self.storedSecret("arkAPIKey", defaults: d)
        arkModel = d.string(forKey: "arkModel") ?? Self.defaultArkModel
        // 这些参数以前属于「方舟」一家，现在两个渠道共用，旧键照样读。
        llmTemperature = Self.storedDouble(d, "llmTemperature")
            ?? Self.storedDouble(d, "arkTemperature") ?? 0
        llmSentenceTimeout = Self.storedDouble(d, "llmSentenceTimeout")
            ?? Self.storedDouble(d, "arkSentenceTimeout") ?? Self.defaultSentenceTimeout
        llmContextSentences = Self.storedInt(d, "llmContextSentences")
            ?? Self.storedInt(d, "arkContextSentences") ?? 2
        llmLengthGuard = d.object(forKey: "llmLengthGuard") as? Bool
            ?? d.object(forKey: "arkLengthGuard") as? Bool ?? true
        llmPrompt = d.string(forKey: "llmPrompt") ?? d.string(forKey: "arkPrompt") ?? ""
        intentRewrite = d.object(forKey: "intentRewrite") as? Bool ?? true
        intentTimeout = Self.storedDouble(d, "intentTimeout") ?? 2.5
        typingMode = TypingMode(rawValue: d.string(forKey: "typingMode") ?? "") ?? .live
        replaceMode = ReplaceMode(rawValue: d.string(forKey: "replaceMode") ?? "") ?? .automatic
        terminalReplace = TerminalReplaceMode(rawValue: d.string(forKey: "terminalReplace") ?? "") ?? .direct
        paintAfterCorrection = d.object(forKey: "paintAfterCorrection") as? Bool ?? true
        cleanFillers = d.object(forKey: "cleanFillers") as? Bool ?? true
        if d.object(forKey: "hotkey") != nil {
            hotkey = d.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
        } else {
            hotkey = .defaultHotkey
        }
        hotkeyMode = HotkeyMode(rawValue: d.string(forKey: "hotkeyMode") ?? "") ?? .hold
        loaded = true
    }

    /// 数字偏好容错读取：历史上可能有字符串写进去。
    private static func storedDouble(_ defaults: UserDefaults, _ key: String) -> Double? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func storedInt(_ defaults: UserDefaults, _ key: String) -> Int? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// API Key 存在应用自己的偏好里，不进钥匙串，避免每次启动都要授权。
    /// 以前存进钥匙串的值会静默搬过来；钥匙串需要弹窗才能读时就放弃，不再打扰。
    private static func storedSecret(_ key: String, defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: key) { return saved }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.andy.daxiangshuo",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        let value = String(decoding: data, as: UTF8.self)
        defaults.set(value, forKey: key)
        SecItemDelete(query as CFDictionary)
        return value
    }

    private func store(_ value: Any?, _ key: String) {
        guard loaded else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// 清除快捷键时存一个空 Data，和「从没设置过、用默认值」区分开。
    private func storeHotkey(_ hotkey: Hotkey?, _ key: String) {
        guard loaded else { return }
        defaults.set(hotkey.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
        onHotkeyChange?()
    }

    private func asrChanged() {
        if loaded { onASRConfigChange?() }
    }

    /// 火山引擎的流式识别配置。
    var asrConfig: ASRConfig {
        ASRConfig(endpoint: Self.orDefault(asrEndpoint, Self.defaultASREndpoint),
                  apiKey: asrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                  resourceID: Self.orDefault(asrResourceID, Self.defaultASRResourceID))
    }

    /// DeepSeek 的整段识别配置。
    var deepseekASRConfig: DeepSeekASRConfig {
        DeepSeekASRConfig(endpoint: Self.orDefault(deepseekASREndpoint, Self.defaultDeepSeekASREndpoint),
                          apiKey: deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// DeepSeek 是整段上传，没有流式结果。
    var asrSupportsLiveTyping: Bool { asrEngine != .deepseek }

    var isSelectedASRConfigured: Bool {
        asrEngine == .deepseek ? deepseekASRConfig.isComplete : asrConfig.isComplete
    }

    /// 每次听写前组好的识别参数，凡是能配的都来自设置。
    func asrOptions(hotwords: [String]) -> ASROptions {
        ASROptions(modelName: Self.orDefault(asrModel, Self.defaultASRModel),
                   sampleRate: VolcProtocol.sampleRate,
                   itn: asrITN,
                   punc: asrPunc,
                   ddc: asrDDC,
                   endWindowMs: min(max(asrEndWindowMs, 200), 3000),
                   forceToSpeechMs: max(asrForceToSpeechMs, 0),
                   resultType: asrResultType.rawValue,
                   nonstream: asrNonstream,
                   hotwords: hotwords)
    }

    /// 纠错配置：按当前选择的渠道取地址、Key、模型，其余参数两个渠道共用。
    var arkConfig: ArkConfig {
        let endpoint: String
        let apiKey: String
        let model: String
        switch llmEngine {
        case .ark:
            endpoint = Self.orDefault(arkEndpoint, Self.defaultArkEndpoint)
            apiKey = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            model = Self.orDefault(arkModel, Self.defaultArkModel)
        case .deepseek:
            endpoint = Self.orDefault(deepseekLLMEndpoint, Self.defaultDeepSeekLLMEndpoint)
            apiKey = deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            model = Self.orDefault(deepseekLLMModel, Self.defaultDeepSeekLLMModel)
        }
        return ArkConfig(endpoint: endpoint,
                         apiKey: apiKey,
                         model: model,
                         temperature: min(max(llmTemperature, 0), 2),
                         sentenceTimeout: min(max(llmSentenceTimeout, 0.3), 10),
                         systemPrompt: Self.orDefault(llmPrompt, ArkClient.defaultSystemPrompt),
                         lengthGuard: llmLengthGuard)
    }

    var contextSentences: Int { min(max(llmContextSentences, 0), 6) }

    /// 本地清理的开关组合。
    var cleanupOptions: IntentNormalizer.Options { .enabled(cleanFillers) }

    /// 把两个渠道的参数都恢复成默认值（API Key 保留，渠道选择也保留）。
    func resetModelParameters() {
        asrEndpoint = Self.defaultASREndpoint
        asrResourceID = Self.defaultASRResourceID
        asrModel = Self.defaultASRModel
        asrNonstream = true
        asrITN = true
        asrPunc = true
        asrDDC = true
        asrResultType = .full
        asrEndWindowMs = Self.defaultEndWindowMs
        asrChunkMs = Self.defaultChunkMs
        asrForceToSpeechMs = 0
        deepseekASREndpoint = Self.defaultDeepSeekASREndpoint
        deepseekLLMEndpoint = Self.defaultDeepSeekLLMEndpoint
        deepseekLLMModel = Self.defaultDeepSeekLLMModel
        llmEnabled = true
        arkEndpoint = Self.defaultArkEndpoint
        arkModel = Self.defaultArkModel
        llmTemperature = 0
        llmSentenceTimeout = Self.defaultSentenceTimeout
        llmContextSentences = 2
        llmLengthGuard = true
        llmPrompt = ""
        intentRewrite = true
        intentTimeout = 2.5
    }

    /// 去掉首尾空白；为空就用默认值。
    private static func orDefault(_ value: String, _ fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var isASRConfigured: Bool { isSelectedASRConfigured }

    /// 启动时检查必填项：语音识别 Key、快捷键；开启了大模型纠错时还要有纠错渠道的 Key。返回第一个缺项所在的页面。
    var firstMissingSection: MainSection? {
        if !isSelectedASRConfigured { return .models }
        if llmEnabled && !arkConfig.isComplete { return .models }
        if hotkey == nil { return .general }
        return nil
    }
    var isLLMReady: Bool { llmEnabled && arkConfig.isComplete }
}
