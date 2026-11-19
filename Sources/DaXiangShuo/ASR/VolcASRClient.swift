import Foundation

/// 新版控制台的鉴权：只需要 X-Api-Key 和 X-Api-Resource-Id。
struct ASRConfig: Equatable {
    var endpoint: String
    var apiKey: String
    var resourceID: String

    var isComplete: Bool {
        !apiKey.isEmpty && !resourceID.isEmpty && URL(string: endpoint)?.scheme?.hasPrefix("ws") == true
    }

    func makeRequest() -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let id = UUID().uuidString
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        return request
    }
}

/// 一条 WebSocket 连接。所有属性只在 ASRConnectionPool.queue 上访问。
final class ASRConnection {
    let task: URLSessionWebSocketTask
    let config: ASRConfig
    let createdAt = HostTime.now()
    private(set) var isOpen = false
    private(set) var isClosed = false
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    init(task: URLSessionWebSocketTask, config: ASRConfig) {
        self.task = task
        self.config = config
    }

    var httpStatus: Int { (task.response as? HTTPURLResponse)?.statusCode ?? 0 }
    var logID: String { (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Tt-Logid") ?? "-" }

    func send(_ frame: Data) {
        task.send(.data(frame)) { [weak self] error in
            guard let error else { return }
            ASRConnectionPool.queue.async { self?.markClosed(error.localizedDescription) }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        onOpen = nil
        onMessage = nil
        onClose = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    fileprivate func didOpen() {
        guard !isClosed else { return }
        isOpen = true
        receiveNext()
        let callback = onOpen
        onOpen = nil
        callback?()
    }

    fileprivate func markClosed(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        let callback = onClose
        onOpen = nil
        onMessage = nil
        onClose = nil
        callback?(reason)
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            ASRConnectionPool.queue.async {
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(.data(let data)):
                    self.onMessage?(data)
                    self.receiveNext()
                case .success(.string(let text)):
                    self.onMessage?(Data(text.utf8))
                    self.receiveNext()
                case .success:
                    self.receiveNext()
                case .failure(let error):
                    self.markClosed(error.localizedDescription)
                }
            }
        }
    }
}

/// 管理连接和一条备用的预连接：会话结束后立刻建好下一条，按键时直接复用，省掉 TLS 握手。
final class ASRConnectionPool: NSObject, URLSessionWebSocketDelegate {
    static let shared = ASRConnectionPool()
    static let queue = DispatchQueue(label: "asr", qos: .userInteractive)

    /// 预连接放太久可能已被 NAT 或服务端静默断开，超过这个时长就不再复用。
    private static let spareMaxAge: Double = 50

    private var urlSession: URLSession!
    private var connections: [Int: ASRConnection] = [:]
    private var spare: ASRConnection?

    private override init() {
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = Self.queue
        delegateQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 6
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// 在 queue 上调用。优先复用活着的预连接（握手中也算），否则新建。
    func take(_ config: ASRConfig) -> ASRConnection? {
        if let candidate = spare {
            spare = nil
            let age = HostTime.seconds(HostTime.now() - candidate.createdAt)
            if !candidate.isClosed, candidate.config == config, age < Self.spareMaxAge {
                Log.asr.debug("复用预连接（已空闲 \(age, format: .fixed(precision: 1)) 秒，open=\(candidate.isOpen)）")
                return candidate
            }
            candidate.close()
        }
        return open(config)
    }

    /// 在 queue 上调用。
    func open(_ config: ASRConfig) -> ASRConnection? {
        guard let request = config.makeRequest() else { return nil }
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 4 << 20
        let connection = ASRConnection(task: task, config: config)
        connections[task.taskIdentifier] = connection
        task.resume()
        return connection
    }

    func refill(_ config: ASRConfig) {
        Self.queue.async {
            guard config.isComplete else { return }
            if let current = self.spare, !current.isClosed, current.config == config { return }
            self.spare?.close()
            guard let connection = self.open(config) else { return }
            connection.onClose = { [weak self, weak connection] reason in
                guard let self, let connection, self.spare === connection else { return }
                self.spare = nil
                let age = HostTime.seconds(HostTime.now() - connection.createdAt)
                Log.asr.info("预连接在 \(age, format: .fixed(precision: 1)) 秒后关闭：\(reason ?? "-", privacy: .public)")
            }
            self.spare = connection
        }
    }

    func dropSpare() {
        Self.queue.async {
            self.spare?.close()
            self.spare = nil
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        connections[webSocketTask.taskIdentifier]?.didOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        connections[webSocketTask.taskIdentifier]?.markClosed("连接被关闭（\(closeCode.rawValue)）\(text)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let connection = connections.removeValue(forKey: task.taskIdentifier)
        connection?.markClosed(error?.localizedDescription ?? "连接已结束")
    }
}

/// 一次听写对应的识别会话。连上之前的音频先存本地，连上后补发，之后实时每包直发。
final class ASRSession: ASRSessionProtocol {
    let supportsLiveTyping = true

    private static let maxBacklogPacket = 6400

    private let config: ASRConfig
    private let requestFrame: Data
    private let fresh: Bool
    private let onEvent: (ASREvent) -> Void
    private let pool = ASRConnectionPool.shared
    private let queue = ASRConnectionPool.queue

    private var connection: ASRConnection?
    private var live = false
    private var backlog: [Data] = []
    private var allAudio: [Data] = []
    private var tail: Data?
    private var lastSent = false
    private var gotResponse = false
    private var retried = false
    private var done = false
    private var sentBytes = 0

    /// onEvent 总是在主线程回调。fresh 为 true 时不用预连接（用于测试连接）。
    init(config: ASRConfig, requestJSON: Data, fresh: Bool = false, onEvent: @escaping (ASREvent) -> Void) {
        self.config = config
        self.requestFrame = VolcProtocol.fullClientRequest(requestJSON)
        self.fresh = fresh
        self.onEvent = onEvent
    }

    func start() {
        queue.async { self.connect() }
    }

    func sendAudio(_ pcm: Data) {
        queue.async {
            guard !self.done, self.tail == nil else { return }
            self.allAudio.append(pcm)
            if self.live {
                self.sendPacket(pcm, last: false)
            } else {
                self.backlog.append(pcm)
            }
        }
    }

    /// 松开快捷键后，把截止时刻前剩下的音频作为最后一包发出。
    func finish(tail pcm: Data) {
        queue.async {
            guard !self.done, self.tail == nil else { return }
            self.tail = pcm.isEmpty ? Data(count: VolcProtocol.bytesPerMs * 10) : pcm
            if self.live { self.sendTail() }
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.done else { return }
                Log.asr.info("等待最终结果超时，结束会话")
                self.complete()
            }
        }
    }

    func cancel() {
        queue.async {
            if !self.done { self.recordUsage() }
            self.done = true
            self.connection?.close()
            self.connection = nil
            if !self.fresh { self.pool.refill(self.config) }
        }
    }

    // MARK: 私有（都在 queue 上）

    private func connect() {
        let next = (fresh || retried) ? pool.open(config) : pool.take(config)
        guard let connection = next else {
            fail("识别接口地址无效")
            return
        }
        self.connection = connection
        live = false
        connection.onMessage = { [weak self] data in self?.handle(data) }
        connection.onClose = { [weak self] reason in self?.connectionClosed(reason) }
        if connection.isOpen {
            opened()
        } else {
            connection.onOpen = { [weak self] in self?.opened() }
        }
    }

    private func opened() {
        guard let connection, !done else { return }
        connection.send(requestFrame)
        live = true
        var packet = Data()
        for chunk in backlog {
            if !packet.isEmpty, packet.count + chunk.count > Self.maxBacklogPacket {
                sendPacket(packet, last: false)
                packet = Data()
            }
            packet.append(chunk)
        }
        if !packet.isEmpty { sendPacket(packet, last: false) }
        backlog.removeAll()
        if tail != nil { sendTail() }
    }

    private func sendTail() {
        guard let tail, !lastSent else { return }
        lastSent = true
        sendPacket(tail, last: true)
    }

    private func sendPacket(_ pcm: Data, last: Bool) {
        sentBytes += pcm.count
        connection?.send(VolcProtocol.audioRequest(pcm, last: last))
    }

    private func handle(_ data: Data) {
        guard !done else { return }
        switch VolcProtocol.parse(data) {
        case .result(let result, let isLast):
            gotResponse = true
            if let result { emit(.result(result)) }
            if isLast { complete() }
        case .error(let code, let message):
            Log.asr.error("识别错误 \(code)：\(message, privacy: .public) logid=\(self.connection?.logID ?? "-", privacy: .public)")
            fail(VolcProtocol.describe(code: code, message: message))
        case .unknown:
            break
        }
    }

    private func connectionClosed(_ reason: String?) {
        guard !done else { return }
        let status = connection?.httpStatus ?? 0
        if status == 401 || status == 403 {
            fail("鉴权失败（HTTP \(status)），请检查 API Key 和资源类型是否已开通")
            return
        }
        if status >= 400 {
            fail("识别服务拒绝连接（HTTP \(status)）")
            return
        }
        if !gotResponse, !retried {
            Log.asr.info("连接断开，换新连接重发全部音频：\(reason ?? "-", privacy: .public)")
            retried = true
            backlog = allAudio
            lastSent = false
            sentBytes = 0   // 重发的是同一段音频，用量只算一次
            connect()
            return
        }
        fail(gotResponse ? "识别连接中断" : "无法连接识别服务：\(reason ?? "网络错误")")
    }

    private func fail(_ message: String) {
        guard !done else { return }
        emit(.failed(message))
        complete()
    }

    private func complete() {
        guard !done else { return }
        done = true
        recordUsage()
        connection?.close()
        connection = nil
        emit(.finished)
        if !fresh { pool.refill(config) }
    }

    /// 按实际发出的音频字节数折算时长（16kHz 16bit 单声道），测试连接不计入。
    private func recordUsage() {
        guard !fresh, sentBytes > 0 else { return }
        UsageStore.shared.record(seconds: Double(sentBytes) / Double(VolcProtocol.bytesPerMs * 1000))
        sentBytes = 0
    }

    private func emit(_ event: ASREvent) {
        let callback = onEvent
        DispatchQueue.main.async { callback(event) }
    }
}

enum ASRTester {
    /// 发送 0.5 秒静音走完整流程，验证鉴权和参数。
    static func run(config: ASRConfig, requestJSON: Data) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { continuation in
            var failure: String?
            var session: ASRSession?
            session = ASRSession(config: config, requestJSON: requestJSON, fresh: true) { event in
                switch event {
                case .failed(let message):
                    failure = message
                case .finished:
                    if let failure, !failure.contains("45000002") {
                        continuation.resume(returning: (false, failure))
                    } else {
                        continuation.resume(returning: (true, "连接成功，鉴权通过"))
                    }
                    session = nil
                case .result:
                    break
                }
            }
            session?.start()
            let silence = Data(count: VolcProtocol.bytesPerMs * 100)
            for _ in 0..<4 { session?.sendAudio(silence) }
            session?.finish(tail: silence)
        }
    }
}
