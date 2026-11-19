import Foundation

/// DeepSeek 语音识别：`POST https://api.deepseek.com/v1/tools/asr`。
/// 一次请求发送完整音频，返回整段文字，没有流式结果——所以录完才知道说了什么。
struct DeepSeekASRConfig: Equatable {
    var endpoint: String
    var apiKey: String

    var isComplete: Bool {
        guard !apiKey.isEmpty, let url = URL(string: endpoint) else { return false }
        if url.scheme == "https" { return true }
        // 本机 mock 用 http，方便调试整条上传链路。
        return url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }
}

/// 一次听写：先把 PCM 攒在内存里，松开快捷键后包成 16kHz 单声道 WAV 一次上传。
/// 服务端限制：单次最长 120 秒、8 MiB。
final class DeepSeekASRSession: ASRSessionProtocol, @unchecked Sendable {
    let supportsLiveTyping = false

    /// 服务端的时长上限。
    static let maxSeconds: Double = 120
    /// 8 MiB 是服务端的体积上限；16k 单声道 16bit 的 120 秒只有约 3.8 MB，时长先到。
    static let maxBytes = 8 << 20

    private static let boundary = "daxiangshuo-boundary-\(UUID().uuidString)"

    private let config: DeepSeekASRConfig
    private let onEvent: (ASREvent) -> Void
    private let queue = DispatchQueue(label: "asr.deepseek")
    private let session: URLSession

    private var audio = Data()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false

    init(config: DeepSeekASRConfig, onEvent: @escaping (ASREvent) -> Void) {
        self.config = config
        self.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// 整段识别没有连接可建，start 什么都不用做。
    func start() {}

    func sendAudio(_ pcm: Data) {
        queue.async {
            guard !self.cancelled, !self.finished, self.task == nil else { return }
            self.audio.append(pcm)
        }
    }

    /// 松开快捷键：把尾包一起打包上传，识别完把结果作为一整句发出去。
    func finish(tail pcm: Data) {
        queue.async {
            guard !self.cancelled, !self.finished, self.task == nil else { return }
            self.audio.append(pcm)
            let recorded = self.audio
            self.audio = Data()

            let bytesPerMs = VolcProtocol.bytesPerMs
            let seconds = Double(recorded.count) / Double(bytesPerMs * 1000)
            guard seconds >= 0.2 else {
                // 太短了，没必要打接口，也没有用量。
                self.emit(.finished)
                return
            }
            guard seconds <= Self.maxSeconds, recorded.count <= Self.maxBytes else {
                self.fail("DeepSeek 单次最多识别 \(Int(Self.maxSeconds)) 秒，这次说了 \(Int(seconds.rounded())) 秒")
                return
            }
            UsageStore.shared.record(seconds: seconds)
            self.upload(recorded)
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.audio = Data()
            self.task?.cancel()
            self.task = nil
        }
    }

    // MARK: 私有

    private func upload(_ pcm: Data) {
        guard config.isComplete, let url = URL(string: config.endpoint) else {
            fail("请先填写 DeepSeek 的 API Key 和接口地址")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(Self.boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(wav: Self.wav(from: pcm))

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { self.handle(data: data, response: response, error: error) }
        }
        self.task = task
        task.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        guard !cancelled, !finished else { return }
        if error != nil {
            fail("网络连接失败，稍后再试")
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data ?? Data()

        guard status == 200 else {
            fail(Self.describeFailure(status: status, body: body))
            return
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = root["text"] as? String else {
            fail("识别结果解析失败")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            emit(.result(ASRResult(text: trimmed,
                                   utterances: [ASRUtterance(text: trimmed, definite: true)])))
        }
        complete()
    }

    private func fail(_ message: String) {
        guard !finished, !cancelled else { return }
        emit(.failed(message))
        complete()
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        task = nil
        emit(.finished)
    }

    private func emit(_ event: ASREvent) {
        let callback = onEvent
        DispatchQueue.main.async { callback(event) }
    }

    // MARK: 编码

    /// 16kHz 单声道 16bit 的 WAV。
    static func wav(from pcm: Data, sampleRate: Int = VolcProtocol.sampleRate) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func be16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func be32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        be32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        be32(16)                       // fmt 块长度
        be16(1)                        // PCM
        be16(1)                        // 单声道
        be32(UInt32(sampleRate))       // 采样率
        be32(UInt32(sampleRate * 2))   // 每秒字节数
        be16(2)                        // 块对齐
        be16(16)                       // 位深
        out.append(contentsOf: Array("data".utf8))
        be32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    private static func formBody(wav: Data) -> Data {
        var body = Data(capacity: wav.count + 256)
        func line(_ text: String) { body.append(Data(text.utf8)) }
        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        line("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        line("\r\n--\(boundary)--\r\n")
        return body
    }

    static func describeFailure(status: Int, body: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return "DeepSeek：\(message)"
        }
        switch status {
        case 400: return "DeepSeek：音频格式不被接受（需要 16bit PCM WAV）"
        case 401, 403: return "DeepSeek：鉴权失败（HTTP \(status)），请检查 API Key"
        case 408: return "DeepSeek：上传超时"
        case 413: return "DeepSeek：音频超过 8 MB"
        case 429: return "DeepSeek：同时请求数超限，稍后再试"
        case 503: return "DeepSeek：服务繁忙，稍后再试"
        case 504: return "DeepSeek：识别超时"
        default: return "DeepSeek：识别失败（HTTP \(status)）"
        }
    }
}

enum DeepSeekASRTester {
    /// 发 0.5 秒静音走完整流程，验证 Key、地址和音频格式。
    static func run(config: DeepSeekASRConfig) async -> (ok: Bool, message: String) {
        guard config.isComplete else { return (false, "配置不完整或接口地址无效") }
        let silence = Data(count: VolcProtocol.bytesPerMs * 500)

        return await withCheckedContinuation { continuation in
            var failure: String?
            var resumed = false
            var session: DeepSeekASRSession?
            session = DeepSeekASRSession(config: config) { event in
                switch event {
                case .failed(let message):
                    failure = message
                case .finished:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: failure.map { (false, $0) } ?? (true, "连接成功，鉴权通过"))
                    session = nil
                case .result:
                    break
                }
            }
            session?.start()
            session?.sendAudio(silence)
            session?.finish(tail: Data())
        }
    }
}
