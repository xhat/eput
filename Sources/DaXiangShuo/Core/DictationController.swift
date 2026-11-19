import AppKit
import Observation

/// 一次按键听写的全部状态，只在主线程访问。
final class DictationSession {
    let mode: TypingMode
    let keyDownHost: UInt64
    let appName: String
    let text: SessionText
    let typer: LiveTyper?
    var asr: ASRSessionProtocol!

    var keyUpHost: UInt64 = 0

    /// 一次听写的耗时拆解，结束时写一行 latency 日志（只打时长，不打内容）。
    struct Trace {
        var keyUpAt: Date?
        var asrFinishedAt: Date?
        var speculationStartedAt: Date?
        var rewriteSentAt: Date?
        var rewriteDoneAt: Date?
        var speculationHit = false
    }
    var trace = Trace()
    /// 松键时就抢跑的那次整段改写；识别尾帧回来后文本没变就直接用它的结果。
    var speculation: (text: String, task: Task<IntentRewrite?, Never>)?

    var asrFinished = false
    var pendingCorrections = 0
    var correctionDeadlineSet = false
    var correctionTasks: [Task<Void, Never>] = []
    var cancelled = false
    /// 已经跑过（或跳过）整段意图改写。
    var intentStarted = false
    /// 整段改写的请求已经发出去，还在等结果：这期间谁都不能提前收尾。
    var intentRunning = false
    /// 松键时已经亮过状态条（「整理中…」或「正在转写…」）。
    var busyShownAtKeyUp = false
    /// 用户中途插手（打字、点鼠标、切 App）：不再整段改写，免得把他写的内容也动了。
    var userIntervened = false
    /// 已进入收尾（不再接受新结果），等上屏队列清空后才真正结束。
    var finalizing = false
    var finalized = false

    init(mode: TypingMode, keyDownHost: UInt64, appName: String, text: SessionText, typer: LiveTyper?) {
        self.mode = mode
        self.keyDownHost = keyDownHost
        self.appName = appName
        self.text = text
        self.typer = typer
    }
}

/// 串起快捷键、麦克风、识别、纠错和上屏。
/// 状态：idle -> recording（胶囊显示，边说边上屏）-> draining（胶囊已隐藏，发完尾包并等最终结果）-> idle
@Observable
final class DictationController {
    enum State { case idle, recording, draining }

    private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    @ObservationIgnored var onStateChange: ((State) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let phrases: PhraseStore
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let capsule = VoiceCapsule()
    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private let inputGuard = InputSourceGuard()
    @ObservationIgnored private let pool = ASRConnectionPool.shared

    /// 最近一次上屏的原文，供「恢复上一句原文」使用。
    private(set) var lastRawText: String?
    @ObservationIgnored private var active: DictationSession?
    /// 终端里光标所在这一行，我们相信现在写着什么（只包含我们打进去的字）。
    /// nil 表示不知道（用户动过键盘/鼠标、切过 App），这时不能用 ⌃U 清整行。
    @ObservationIgnored private var terminalLineText: String? = nil
    /// 已松开、还在收尾的会话，按开始顺序排列；上屏也按这个顺序轮流进行。
    @ObservationIgnored private var draining: [DictationSession] = []
    @ObservationIgnored private(set) var requestJSON = Data()
    @ObservationIgnored private var processor = TextPostProcessor(replacements: [])
    @ObservationIgnored private var glossary: [String] = []
    @ObservationIgnored private var refillWork: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// 按下不足这个时长就松开，视为误触。
    private static let misfireMs: Double = 150
    /// 按住说话键后这么快就按了别的键，说明是在用组合快捷键，不是在说话。
    private static let shortcutMs: Double = 300

    init(settings: AppSettings, history: HistoryStore, phrases: PhraseStore) {
        self.settings = settings
        self.history = history
        self.phrases = phrases
    }

    var hotkeysReady: Bool { hotkeys.isRunning }

    func start() {
        capsule.levelProvider = { [audio] in audio.level }
        capsule.liveProvider = { [audio] in audio.isLive }
        audio.onInterrupted = { [weak self] failure in
            DispatchQueue.main.async { self?.inputInterrupted(failure) }
        }

        hotkeys.onPTTDown = { [weak self] host in DispatchQueue.main.async { self?.begin(at: host) } }
        hotkeys.onPTTUp = { [weak self] host in DispatchQueue.main.async { self?.end(at: host) } }
        hotkeys.onToggle = { [weak self] host in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.active == nil { self.begin(at: host) } else { self.end(at: host) }
            }
        }
        hotkeys.onUserKey = { [weak self] held in DispatchQueue.main.async { self?.userPressedKey(pttHeld: held) } }
        hotkeys.onUserTyping = { [weak self] keyCode in
            DispatchQueue.main.async {
                guard let self else { return }
                // 回车/小键盘回车：这一行交出去了，缓冲区清空。
                // 其它任何键（含 Esc、⌃U、⌃W）：这一行可能有我们不知道的内容了。
                self.terminalLineText = (keyCode == 36 || keyCode == 76) ? "" : nil
            }
        }
        hotkeys.onUserMouse = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminalLineText = nil
                self.freezeTyping()
            }
        }
        applyHotkeys()
        hotkeys.start()

        rebuildRequest()
        phrases.onChange = { [weak self] in self?.rebuildRequest() }
        settings.onASRConfigChange = { [weak self] in self?.asrConfigChanged() }
        settings.onHotkeyChange = { [weak self] in self?.applyHotkeys() }
        audio.warmUp()
        refillPool()
        if settings.isLLMReady { ArkClient.shared.warmUp(settings.arkConfig) }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.freezeTyping()
            // 换了个 App/窗口，这一行是什么状态我们不知道了。
            self.terminalLineText = nil
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refillPool()
        })
    }

    func shutdown() {
        audio.shutdown()
        inputGuard.restore()
    }

    // MARK: 按键

    private func begin(at host: UInt64) {
        guard active == nil else { return }
        let config = settings.asrConfig
        guard settings.isSelectedASRConfigured else {
            capsule.showError(settings.asrEngine == .deepseek
                              ? "请先在模型设置里填写 DeepSeek 的 API Key"
                              : "请先在模型设置里填写火山引擎的 API Key")
            return
        }
        guard !Permissions.microphoneDenied else {
            capsule.showError("没有麦克风权限，请在系统设置中允许大象说使用麦克风")
            return
        }
        // 没有输入设备时绝不能往下走：AVAudioEngine 会在建图时抛 ObjC 异常，直接把进程 abort。
        guard AudioInput.current().isReady else {
            capsule.showNotice("没有检测到麦克风，请检查系统的声音输入设置")
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        let mode = settings.typingMode
        // DeepSeek 是整段识别，说不完就没有字，所以不参与逐字上屏。
        let liveTyping = settings.asrSupportsLiveTyping

        // 等纠错再落字时输入框里暂时不写字，就把实时文本显示在胶囊上（粘帖模式本来也这么用）。
        let previewInCapsule = liveTyping && (mode == .paste || settings.paintAfterCorrection)
        capsule.show(preview: previewInCapsule)

        let typer = (mode == .live && liveTyping)
            ? LiveTyper(enabled: draining.isEmpty,
                        clipboardReplacement: settings.replaceMode == .automatic,
                        terminalMode: settings.terminalReplace,
                        linePrefix: { [weak self] in self?.terminalLineText })
            : nil
        let session = DictationSession(mode: mode, keyDownHost: host, appName: front?.localizedName ?? "",
                                       text: SessionText(processor: processor,
                                                         contextSentences: settings.contextSentences,
                                                         cleanup: settings.cleanupOptions,
                                                         paintAfterCorrection: settings.paintAfterCorrection),
                                       typer: typer)
        let onEvent: (ASREvent) -> Void = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, for: session)
        }
        let asr: ASRSessionProtocol
        if settings.asrEngine == .deepseek {
            asr = DeepSeekASRSession(config: settings.deepseekASRConfig, onEvent: onEvent)
        } else {
            // 上下文要的是「刚刚说完的几句」，所以每轮现组一次；没开就用手上缓存的。
            let body = settings.asrContext
                ? VolcProtocol.requestJSON(settings.asrOptions(hotwords: glossary),
                                           context: history.recentTexts(limit: 3))
                : requestJSON
            asr = ASRSession(config: config, requestJSON: body, onEvent: onEvent)
        }
        session.asr = asr
        active = session
        state = .recording
        hotkeys.setSessionActive(true)

        asr.start()
        audio.begin(chunkMs: min(max(settings.asrChunkMs, 40), 200),
                    onChunk: { asr.sendAudio($0) },
                    onFinish: { asr.finish(tail: $0) },
                    onFailure: { [weak self, weak session] failure in
                        DispatchQueue.main.async {
                            guard let self, let session else { return }
                            self.abort(session, message: failure.message)
                        }
                    })

        if mode == .live, liveTyping { inputGuard.switchToASCIIIfNeeded() }
        if settings.isLLMReady { ArkClient.shared.warmUp(settings.arkConfig) }
    }

    private func end(at host: UInt64) {
        guard let session = active else { return }
        moveToDraining(session)
        session.keyUpHost = host
        if HostTime.ms(from: session.keyDownHost, to: host) < Self.misfireMs {
            capsule.hide()
            cancel(session)
            return
        }
        // 松键立刻给反馈，别让人等一秒才看到「整理中」：
        // 整段识别（DeepSeek）先等上传出字，流式识别能整理就直接进「整理中」。
        session.trace.keyUpAt = Date()
        if !session.asr.supportsLiveTyping {
            session.busyShownAtKeyUp = true
            capsule.showBusy("正在转写…")
        } else if rewritePossible {
            session.busyShownAtKeyUp = true
            capsule.showBusy("整理中…")
            startSpeculation(session)
        } else if settings.paintAfterCorrection {
            // 文字还在等定稿：把刚说的那段字留在胶囊上，只在左边加个「还在算」的符号。
            session.busyShownAtKeyUp = true
            capsule.showFinalizing(session.text.preview)
        } else {
            capsule.hide()
        }
        audio.end(at: host)
    }

    private func userPressedKey(pttHeld: Bool) {
        if pttHeld, let session = active,
           HostTime.ms(from: session.keyDownHost, to: HostTime.now()) < Self.shortcutMs {
            capsule.hide()
            moveToDraining(session)
            cancel(session)
            return
        }
        freezeTyping()
    }

    /// 用户点了鼠标、自己打了字或切了 App：已上屏的内容固定下来，不再退格修改。
    private func freezeTyping() {
        active?.typer?.freeze()
        active?.userIntervened = true
        for session in draining { session.typer?.freeze() }
    }

    /// 这一次听写之后会不会跑整段改写（不看文本，只看开关和渠道）。
    private var rewritePossible: Bool {
        settings.intentRewrite && settings.arkConfig.isComplete
    }

    /// 松键就先把整段改写发出去。识别尾帧（600ms 静音判定 + 二遍识别）通常只把最后一句标成
    /// definite，文字本身没变——那就白赚这 0.3～0.7 秒；文字变了就丢掉这次结果，用最终文本重发，
    /// 最坏也不过回到以前的速度。
    private func startSpeculation(_ session: DictationSession) {
        guard settings.intentRewrite, !session.cancelled, !session.userIntervened else { return }
        let text = session.text.target
        guard IntentRewriter.shouldRewrite(text) else { return }
        let config = settings.arkConfig
        guard config.isComplete else { return }
        let glossary = self.glossary
        let timeout = min(max(settings.intentTimeout, 0.3), 5)
        session.trace.speculationStartedAt = Date()
        session.speculation = (text, Task {
            await ArkClient.shared.rewrite(text, glossary: glossary, config: config, timeout: timeout)
        })
    }

    /// 真正能跑整段改写的计划：开关、渠道、用户是否插手、文本够不够长都过一遍。
    /// 返回 nil 表示这一轮不做改写。
    private func rewritePlan(_ session: DictationSession) -> (target: String, config: ArkConfig)? {
        let target = session.text.target
        let config = settings.arkConfig
        guard settings.intentRewrite,
              !session.cancelled,
              !session.userIntervened,
              config.isComplete,
              IntentRewriter.shouldRewrite(target)
        else { return nil }
        return (target, config)
    }

    private func moveToDraining(_ session: DictationSession) {
        if active === session { active = nil }
        if !draining.contains(where: { $0 === session }) { draining.append(session) }
        state = .draining
    }

    private func cancel(_ session: DictationSession) {
        session.cancelled = true
        audio.cancel()
        session.asr.cancel()
        finalize(session)
    }

    private func abort(_ session: DictationSession, message: String) {
        guard !session.finalizing else { return }
        capsule.showError(message)
        let wasActive = active === session
        moveToDraining(session)
        if wasActive { audio.cancel() }
        session.asr.cancel()
        finalize(session)
    }

    /// 录到一半麦克风被拔掉：按失败收尾，已经识别出的文字照常上屏。
    private func inputInterrupted(_ failure: AudioCapture.Failure) {
        guard let session = active else { return }
        abort(session, message: failure.message)
    }

    var hasRawToRestore: Bool {
        !(lastRawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 把上一句的原始转录贴回去——意图改写不满意时用。
    func restoreLastRaw() {
        guard let raw = lastRawText, !raw.isEmpty else { return }
        PasteInserter.paste(raw)
    }

    /// 辅助功能没授权时安静地提一句：全局快捷键收不到，也写不进别的输入框。
    func notifyAccessibilityMissing() {
        guard !Permissions.accessibilityGranted else { return }
        capsule.showNotice("辅助功能未授权，快捷键暂时无效", symbol: "exclamationmark.triangle.fill")
    }

    /// 启动时如果没有可用的输入设备，做一次安静的非模态提示，让人知道快捷键为什么不响应。
    func notifyMissingInputIfNeeded() {
        guard !AudioInput.current().isReady else { return }
        capsule.showNotice("没有检测到麦克风，语音输入暂时不可用")
    }

    // MARK: 识别结果

    private func handle(_ event: ASREvent, for session: DictationSession) {
        switch event {
        case .result(let result):
            guard !session.finalizing else { return }
            for index in session.text.apply(result) { startCorrection(at: index, in: session) }
            push(session)
        case .failed(let message):
            Log.asr.error("\(message, privacy: .public)")
            // 识别链路自己报错：按失败收尾，别把会话留在 draining 里（那样状态再也不会回到 idle）。
            if active === session {
                abort(session, message: message)
            } else {
                capsule.showError(message)
                session.asr.cancel()
                finalize(session)
            }
        case .finished:
            session.asrFinished = true
            session.trace.asrFinishedAt = Date()
            // 状态条不用在这里收：要改写就换成「整理中…」，不改写就由 finalize 收尾时收掉。
            maybeFinalize(session)
        }
    }

    private func push(_ session: DictationSession) {
        let target = session.text.target
        if let typer = session.typer {
            typer.update(target)
            // 输入框里还没落字，实时文本先显示在胶囊上。
            if session === active, settings.paintAfterCorrection {
                capsule.setPreview(session.text.preview)
            }
        } else if session === active {
            capsule.setPreview(session.text.preview)
        }
    }

    private func startCorrection(at index: Int, in session: DictationSession) {
        guard settings.isLLMReady, !session.cancelled, index < session.text.sentences.count else { return }
        let sentence = session.text.sentences[index]
        let source = sentence.processed
        guard source.count >= 2, source.contains(where: \.isLetter) else { return }
        let version = sentence.version
        let context = session.text.context(before: index)
        let config = settings.arkConfig
        let glossary = self.glossary
        let processor = self.processor

        // 最后一句、而且还没开始说下一句：先不上屏，等这次纠错回来一次画上，
        // 免得每句话都「二遍识别闪一次、纠错再闪一次」。
        if index == session.text.sentences.count - 1, session.text.tail.isEmpty {
            session.text.holdLastSentence()
        }
        session.pendingCorrections += 1
        let task = Task { @MainActor [weak self, weak session] in
            let output = await ArkClient.shared.correct(sentence: source, context: context,
                                                        glossary: glossary, config: config)
            guard let self, let session else { return }
            session.pendingCorrections -= 1
            session.text.releaseHold()
            if !session.finalizing {
                if let output {
                    _ = session.text.setCorrection(processor.apply(output), at: index, version: version)
                }
                self.push(session)
            }
            self.maybeFinalize(session)
        }
        session.correctionTasks.append(task)
    }

    // MARK: 收尾

    private func maybeFinalize(_ session: DictationSession) {
        guard session.asrFinished, !session.finalizing else { return }
        // 要跑整段改写就不用等逐句纠错：改写结果整段覆盖，早发出去早回来。
        if session.pendingCorrections > 0, rewritePlan(session) == nil {
            guard !session.correctionDeadlineSet else { return }
            session.correctionDeadlineSet = true
            // 等晚到的逐句纠错，但不要等满整个单句上限：否则松键后要卡一两秒才开始定稿。
            let wait = min(settings.arkConfig.sentenceTimeout, 1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak session] in
                guard let self, let session else { return }
                self.advanceToIntent(session)
            }
            return
        }
        advanceToIntent(session)
    }

    /// 逐句纠错都回来了：按设置跑一次整段意图改写，然后收尾。
    /// 任何一环不满足（关掉了、用户插手了、太短、渠道没配好）都直接收尾。
    private func advanceToIntent(_ session: DictationSession) {
        guard !session.finalizing else { return }
        // 改写已经发出去了，收尾只能由那个改写任务来做。
        // 否则晚到的逐句纠错会把原文先贴出去，改写结果回来时又因为已经 finalize 被丢掉，
        // 胶囊还会一直停在「整理中…」。
        guard !session.intentRunning else { return }
        guard !session.intentStarted else {
            finalize(session)
            return
        }
        session.intentStarted = true

        guard let plan = rewritePlan(session) else {
            finalize(session)
            return
        }
        let target = plan.target
        let config = plan.config

        session.intentRunning = true
        // 松键时已经亮过状态条：等定稿的模式下保留「跑动的波 + 刚说的文字」，不换成文字提示。
        if session.busyShownAtKeyUp {
            if !settings.paintAfterCorrection { capsule.setBusyText("整理中…") }
        } else {
            capsule.showBusy("整理中…")
        }
        let glossary = self.glossary
        let timeout = min(max(settings.intentTimeout, 0.3), 5)
        let speculation = session.speculation
        session.speculation = nil
        session.trace.rewriteSentAt = Date()
        // 兵卒保险：改写请求本身已经带了超时，但如果连超时都没生效（卡在网络上），
        // 这里也要把这一轮强制收尾，不能把「整理中…」和这一轮听写一起卡死。
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 1) { [weak self, weak session] in
            guard let self, let session, session.intentRunning, !session.finalizing else { return }
            session.intentRunning = false
            self.capsule.clearNotice()
            self.finalize(session)
        }
        Task { @MainActor [weak self, weak session] in
            var hit = false
            let rewrite: IntentRewrite?
            if let speculation, speculation.text == target {
                // 抢跑的那次就是冲着这段文本发的：直接等它，不用再发一次。
                hit = true
                rewrite = await speculation.task.value
            } else {
                speculation?.task.cancel()
                rewrite = await ArkClient.shared.rewrite(target, glossary: glossary,
                                                         config: config, timeout: timeout)
            }
            guard let self else { return }
            self.capsule.clearNotice()
            guard let session, !session.finalizing else { return }
            session.intentRunning = false
            session.trace.speculationHit = hit
            session.trace.rewriteDoneAt = Date()
            if let rewrite {
                session.text.setFinal(rewrite.text)
            }
            self.finalize(session)
        }
    }

    private func finalize(_ session: DictationSession) {
        guard !session.finalizing else { return }
        session.finalizing = true
        // 收尾了：扣着等纠错的那句、还有正在说的那半句，都得放行，不然上屏会缺字。
        session.text.finishPaint()
        // 抢跑的那次改写如果没用上（用户插手、取消、文本太短），结果就不要了。
        session.speculation?.task.cancel()
        session.speculation = nil
        // 收尾时把「正在转写 / 整理中」这类没有到时间的状态条收掉，免得它一直挂着。
        // 只在这一轮是最后一轮时收：前面几轮收尾不能影响正在录的新一轮。
        if active == nil, draining.last === session { capsule.clearNotice() }
        session.correctionTasks.forEach { $0.cancel() }

        if let typer = session.typer {
            if !session.cancelled { typer.update(session.text.target) }
            // 还没轮到这一轮上屏时，等上一轮结束后由 completeFinalize 接力。
            if typer.isEnabled {
                typer.whenIdle { DispatchQueue.main.async { self.completeFinalize(session) } }
            }
        } else {
            if !session.cancelled { PasteInserter.paste(session.text.target) }
            completeFinalize(session)
        }
    }

    private func completeFinalize(_ session: DictationSession) {
        guard !session.finalized else { return }
        session.finalized = true
        draining.removeAll { $0 === session }
        logLatency(session)
        // 这一行上现在多了我们这次落下的字；记账跟着更新（不知道就继续不知道）。
        if !session.cancelled, !session.text.target.isEmpty, var line = terminalLineText {
            line += session.text.target
            terminalLineText = line
        }

        let text = session.text.target
        if !session.cancelled, !text.isEmpty {
            let duration = HostTime.seconds(max(session.keyUpHost, session.keyDownHost) - session.keyDownHost)
            history.add(raw: session.text.rawText, text: text, duration: duration, app: session.appName)
            lastRawText = session.text.rawText
        }

        if let next = draining.first ?? active, let typer = next.typer, !typer.isEnabled {
            typer.enable()
            if next.finalizing {
                typer.whenIdle { DispatchQueue.main.async { self.completeFinalize(next) } }
            }
        }

        if active == nil, draining.isEmpty {
            inputGuard.restore()
            hotkeys.setSessionActive(false)
            state = .idle
        }
    }

    // MARK: 配置变化

    /// 一轮听写的耗时拆解：看一行日志就知道该优化哪一段，不用猜。
    /// `log show --last 10m --predicate 'subsystem == "com.andy.daxiangshuo" AND category == "latency"'`
    private func logLatency(_ session: DictationSession) {
        let trace = session.trace
        func step(_ from: Date?, _ to: Date?) -> String {
            guard let from, let to else { return "-" }
            return "\(Int((to.timeIntervalSince(from) * 1000).rounded()))"
        }
        let line = "松键→尾帧 \(step(trace.keyUpAt, trace.asrFinishedAt))ms，"
            + "尾帧→发请求 \(step(trace.asrFinishedAt, trace.rewriteSentAt))ms，"
            + "请求→结果 \(step(trace.rewriteSentAt, trace.rewriteDoneAt))ms，"
            + "结果→上屏 \(step(trace.rewriteDoneAt ?? trace.asrFinishedAt, Date()))ms，"
            + "抢跑\(trace.speculationHit ? "命中" : "未命中")，"
            + "\(session.text.target.count) 字"
        Log.latency.notice("\(line, privacy: .public)")
    }

    private func applyHotkeys() {
        switch settings.hotkeyMode {
        case .hold: hotkeys.configure(hold: settings.hotkey, toggle: nil)
        case .toggle: hotkeys.configure(hold: nil, toggle: settings.hotkey)
        }
    }

    /// 设置页录制快捷键期间暂停全局快捷键。
    func setHotkeysSuspended(_ suspended: Bool) {
        hotkeys.setSuspended(suspended)
    }

    private func rebuildRequest() {
        processor = TextPostProcessor(replacements: phrases.replacements)
        glossary = phrases.hotwords
        requestJSON = VolcProtocol.requestJSON(settings.asrOptions(hotwords: glossary))
    }

    /// 只有火山引擎的流式识别需要预连接；换成 DeepSeek 就把备用连接丢掉。
    private func refillPool() {
        if settings.asrEngine == .volcengine {
            pool.refill(settings.asrConfig)
        } else {
            pool.dropSpare()
        }
    }

    private func asrConfigChanged() {
        rebuildRequest()
        refillWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refillPool()
        }
        refillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
