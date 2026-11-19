import AVFoundation

/// 音频实时线程和处理线程之间的采样缓冲（单声道 Float32，采样率为硬件原始采样率）。
/// 临界区只有 memcpy，实时线程里不做内存分配。
final class SampleRing: @unchecked Sendable {
    struct Drained {
        var reachedCutoff: Bool
        var cutoffHost: UInt64
        var sampleRate: Double
    }

    let signal = DispatchSemaphore(value: 0)

    private let lock = UnfairLock()
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var count = 0
    private var armed = false
    private var cutoffHost: UInt64 = 0
    private var cutoffReached = false
    private var level: Float = 0
    private var sampleRate: Double = 48000
    /// 本轮听写第一批采样到达的时刻，0 表示麦克风还没开始收音。
    private var firstWriteHost: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        // 不预先清零：只有真正写入的页才会占用物理内存。
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    var currentLevel: Float { lock.withLock { level } }
    var firstSampleHost: UInt64 { lock.withLock { firstWriteHost } }

    func configure(sampleRate: Double) {
        lock.withLock { self.sampleRate = sampleRate }
    }

    func arm() {
        lock.withLock {
            armed = true
            writeIndex = 0
            count = 0
            cutoffHost = 0
            cutoffReached = false
            firstWriteHost = 0
        }
    }

    func disarm() {
        lock.withLock { armed = false }
    }

    func resetLive() {
        lock.withLock { firstWriteHost = 0 }
    }

    /// 松开快捷键的时刻。之后只保留采集时间早于这个时刻的采样。
    func setCutoff(_ host: UInt64) {
        lock.withLock { cutoffHost = max(host, 1) }
    }

    /// 在音频实时线程调用。hostTime 是这一批第一个采样的采集时刻。
    func write(_ src: UnsafePointer<Float>, frames: Int, hostTime: UInt64, rms: Float) {
        lock.lock()
        level = rms
        guard armed, !cutoffReached else {
            lock.unlock()
            return
        }
        var n = frames
        if cutoffHost != 0 {
            if hostTime >= cutoffHost {
                n = 0
            } else {
                n = min(frames, Int(HostTime.seconds(cutoffHost - hostTime) * sampleRate))
            }
            if n < frames { cutoffReached = true }
        }
        if n > 0 {
            if firstWriteHost == 0 { firstWriteHost = mach_absolute_time() }
            let first = min(n, capacity - writeIndex)
            (storage + writeIndex).update(from: src, count: first)
            if first < n { storage.update(from: src + first, count: n - first) }
            writeIndex = (writeIndex + n) % capacity
            count = min(count + n, capacity)
        }
        lock.unlock()
        signal.signal()
    }

    func drain(into out: inout [Float]) -> Drained {
        lock.lock()
        defer { lock.unlock() }
        out.removeAll(keepingCapacity: true)
        if count > 0 {
            let start = (writeIndex - count + capacity) % capacity
            let first = min(count, capacity - start)
            out.append(contentsOf: UnsafeBufferPointer(start: storage + start, count: first))
            if first < count {
                out.append(contentsOf: UnsafeBufferPointer(start: storage, count: count - first))
            }
            count = 0
        }
        return Drained(reachedCutoff: cutoffReached, cutoffHost: cutoffHost, sampleRate: sampleRate)
    }
}

/// 每次听写一个实例：把缓冲里的采样转成 16kHz Int16，攒满一包（默认 100ms）就立刻交给发送端。
final class CaptureConsumer: @unchecked Sendable {
    var onDone: (() -> Void)?

    private let ring: SampleRing
    private let chunkBytes: Int
    private let onChunk: (Data) -> Void
    private let onFinish: (Data) -> Void
    private let flags = UnfairLock()
    private var cancelled = false
    private var forced = false
    private let finished = DispatchSemaphore(value: 0)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var pcm: [UInt8] = []
    private var samples: [Float] = []

    init(ring: SampleRing, chunkBytes: Int, onChunk: @escaping (Data) -> Void, onFinish: @escaping (Data) -> Void) {
        self.ring = ring
        self.chunkBytes = chunkBytes
        self.onChunk = onChunk
        self.onFinish = onFinish
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "audio.consumer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() {
        flags.withLock { cancelled = true }
        ring.signal.signal()
    }

    /// 新一轮听写抢占时调用：立刻把已采到的部分作为最后一包发出。
    func forceFinish(waitUpTo seconds: Double) {
        flags.withLock { forced = true }
        ring.signal.signal()
        _ = finished.wait(timeout: .now() + seconds)
    }

    private func run() {
        samples.reserveCapacity(96_000)
        pcm.reserveCapacity(chunkBytes * 4)
        while true {
            _ = ring.signal.wait(timeout: .now() + .milliseconds(20))
            let (isCancelled, isForced) = flags.withLock { (cancelled, forced) }
            if isCancelled { break }

            let drained = ring.drain(into: &samples)
            if !samples.isEmpty {
                convert(samples, rate: drained.sampleRate)
                while pcm.count >= chunkBytes {
                    onChunk(Data(pcm[0..<chunkBytes]))
                    pcm.removeFirst(chunkBytes)
                }
            }

            let timedOut = drained.cutoffHost != 0
                && HostTime.now() > drained.cutoffHost + HostTime.ticks(ms: 400)
            if drained.reachedCutoff || isForced || timedOut {
                if let converter { run(converter, input: nil) }
                onFinish(Data(pcm))
                pcm.removeAll()
                break
            }
        }
        finished.signal()
        onDone?()
    }

    private func convert(_ input: [Float], rate: Double) {
        if converter == nil || converterRate != rate {
            guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: 1, interleaved: false) else { return }
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converterRate = rate
        }
        guard let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                            frameCapacity: AVAudioFrameCount(input.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: input.count) }
        run(converter, input: buffer)
    }

    /// input 为 nil 表示音频结束，把转换器内部残留的采样也冲出来。
    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?) {
        let inFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(inFrames * 16000 / max(converterRate, 1)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard let input else {
                status.pointee = .endOfStream
                return nil
            }
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard out.frameLength > 0, let data = out.int16ChannelData?[0] else { return }
        let bytes = UnsafeRawBufferPointer(start: data, count: Int(out.frameLength) * 2)
        pcm.append(contentsOf: bytes)
    }
}

/// 麦克风采集。用 AVAudioSinkNode 按硬件 IO 周期（约 10ms）拿数据，而不是间隔约 100ms 的 installTap。
final class AudioCapture: @unchecked Sendable {
    enum Failure {
        /// 系统里没有任何输入设备。
        case noInput
        /// 有设备但没有可用的输入声道。
        case deviceUnavailable
        /// 设备刚插拔过，系统的音频格式还没稳定下来。
        case switching
        /// 有设备，但引擎起不来。
        case startFailed
        /// 正在说话时麦克风被拔掉。
        case interrupted

        var message: String {
            switch self {
            case .noInput: "没有检测到麦克风，请检查系统的声音输入设置"
            case .deviceUnavailable: "当前的声音输入设备不可用，请换一个输入设备"
            case .switching: "声音输入设备正在切换，请再按一次快捷键"
            case .startFailed: "麦克风启动失败，请检查系统的声音输入设置"
            case .interrupted: "麦克风已断开，这次听写已取消"
            }
        }
    }

    /// 录音过程中设备被拔掉时在主线程回调。
    var onInterrupted: ((Failure) -> Void)?

    var level: Float { ring.currentLevel }
    var isLive: Bool { ring.firstSampleHost != 0 }

    private let control = DispatchQueue(label: "audio.control", qos: .userInteractive)
    /// 处理线程每 20ms 取一次，2 秒的余量足够。
    private let ring = SampleRing(capacity: 96_000 * 2)
    private static let monoCapacity = 16_384
    private let mono: UnsafeMutablePointer<Float>
    private var engine: AVAudioEngine?
    private var consumer: CaptureConsumer?
    private var configObserver: NSObjectProtocol?

    init() {
        mono = .allocate(capacity: Self.monoCapacity)
        _ = HostTime.nsPerTick
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.control.async { self?.rebuildAfterDeviceChange() }
        }
    }

    deinit { mono.deallocate() }

    /// 启动时调用一次：让系统提前加载音频驱动和插件，然后立刻释放引擎。
    /// 不预热的话，进程里第一次录音要多等 1 秒以上。
    func warmUp() {
        control.async {
            guard self.consumer == nil else { return }
            guard self.ensureGraph() == nil else { return }
            self.releaseEngine()
        }
    }

    func begin(chunkMs: Int,
               onChunk: @escaping (Data) -> Void,
               onFinish: @escaping (Data) -> Void,
               onFailure: @escaping (Failure) -> Void) {
        ring.resetLive()
        control.async {
            if let previous = self.consumer {
                previous.forceFinish(waitUpTo: 0.05)
                self.consumer = nil
            }
            if let failure = self.ensureGraph() {
                self.ring.disarm()
                onFailure(failure)
                return
            }
            self.ring.arm()
            let consumer = CaptureConsumer(ring: self.ring, chunkBytes: chunkMs * VolcProtocol.bytesPerMs,
                                           onChunk: onChunk, onFinish: onFinish)
            consumer.onDone = { [weak self, weak consumer] in
                self?.control.async {
                    guard let self, let consumer, self.consumer === consumer else { return }
                    self.consumer = nil
                    self.ring.disarm()
                    self.releaseEngine()
                }
            }
            self.consumer = consumer
            consumer.start()
            if !self.startEngine() {
                self.consumer = nil
                consumer.cancel()
                self.ring.disarm()
                self.releaseEngine()
                onFailure(.startFailed)
            }
        }
    }

    /// hostTime 是松开快捷键的时刻；在这之前采到的音频会全部发完。
    func end(at hostTime: UInt64) {
        control.async { self.ring.setCutoff(hostTime) }
    }

    func cancel() {
        control.async {
            self.consumer?.cancel()
            self.consumer = nil
            self.ring.disarm()
            self.releaseEngine()
        }
    }

    func shutdown() {
        control.sync {
            consumer?.cancel()
            engine?.stop()
        }
    }

    // MARK: 私有

    @discardableResult
    private func startEngine() -> Bool {
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            Log.audio.error("engine start 失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 听写一结束就停掉麦克风并释放整个音频图，平时不占音频资源和内存。
    private func releaseEngine() {
        guard consumer == nil, let engine else { return }
        engine.stop()
        self.engine = nil
    }

    private func rebuildAfterDeviceChange() {
        Log.audio.info("音频设备变化，重建音频图")
        engine?.stop()
        engine = nil
        guard let consumer else { return }
        if let failure = ensureGraph() {
            interrupt(consumer, with: failure)
            return
        }
        if !startEngine() {
            interrupt(consumer, with: .startFailed)
        }
    }

    /// 录到一半设备没了：收尾掉这一次采集，并告知上层取消这次听写。
    private func interrupt(_ consumer: CaptureConsumer, with failure: Failure) {
        Log.audio.error("录音中断：\(failure.message, privacy: .public)")
        self.consumer = nil
        consumer.cancel()
        ring.disarm()
        releaseEngine()
        onInterrupted?(failure)
    }

    /// 建音频图。返回 nil 表示成功，否则返回失败原因。
    /// 必须先问 CoreAudio 再碰 AVAudioEngine：没有输入设备时 connect 会抛 ObjC 异常，进程直接崩。
    private func ensureGraph() -> Failure? {
        if engine != nil { return nil }

        let device: AudioInput.Device
        switch AudioInput.current() {
        case .noDevice:
            Log.audio.error("系统里没有可用的输入设备")
            return .noInput
        case .noChannels(let found):
            Log.audio.error("「\(found.name, privacy: .public)」没有输入声道")
            return .deviceUnavailable
        case .ready(let found):
            device = found
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.audio.error("输入格式不可用：\(format.sampleRate) Hz，\(format.channelCount) 声道")
            return .deviceUnavailable
        }
        // 刚插拔过设备时，AVFoundation 报的采样率会和硬件暂时对不上，
        // 说明它还没拿到新设备的格式，这时 connect 有可能抛异常。等下一次按键再建图。
        if device.sampleRate > 0, abs(format.sampleRate - device.sampleRate) > 0.5 {
            Log.audio.error("设备采样率 \(device.sampleRate) Hz 与音频图 \(format.sampleRate) Hz 不一致")
            return .switching
        }
        ring.configure(sampleRate: format.sampleRate)

        let ring = self.ring
        let mono = self.mono
        let monoCapacity = Self.monoCapacity
        let inputRate = format.sampleRate
        let sink = AVAudioSinkNode { timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            let frames = min(Int(frameCount), monoCapacity)
            guard frames > 0, buffers.count > 0,
                  let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            var source = UnsafePointer(first)
            if buffers.count > 1 || buffers[0].mNumberChannels > 1 {
                var totalChannels = 0
                for f in 0..<frames { mono[f] = 0 }
                for buffer in buffers {
                    let nch = Int(buffer.mNumberChannels)
                    guard nch > 0, let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    totalChannels += nch
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<nch { sum += p[f * nch + c] }
                        mono[f] += sum
                    }
                }
                let scale = 1 / Float(max(totalChannels, 1))
                for f in 0..<frames { mono[f] *= scale }
                source = UnsafePointer(mono)
            }

            var energy: Float = 0
            for f in 0..<frames { energy += source[f] * source[f] }
            let rms = (energy / Float(frames)).squareRoot()

            let ts = timestamp.pointee
            let host = ts.mFlags.contains(.hostTimeValid)
                ? ts.mHostTime
                : HostTime.now() &- HostTime.ticks(ms: Double(frames) * 1000 / inputRate)
            ring.write(source, frames: frames, hostTime: host, rms: rms)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        self.engine = engine
        Log.audio.info("音频图就绪：\(format.sampleRate) Hz，\(format.channelCount) 声道（\(device.name, privacy: .public)）")
        return nil
    }
}
