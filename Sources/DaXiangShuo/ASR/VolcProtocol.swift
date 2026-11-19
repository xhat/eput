import Compression
import Foundation

struct ASRUtterance: Equatable {
    var text: String
    var definite: Bool
}

struct ASRResult: Equatable {
    var text: String
    var utterances: [ASRUtterance]
}

/// 一次听写要用到的识别参数，全部来自「模型设置」。
struct ASROptions: Equatable {
    var modelName: String
    var sampleRate: Int
    var itn: Bool
    var punc: Bool
    var ddc: Bool
    var endWindowMs: Int
    var forceToSpeechMs: Int
    /// `full`（完整结果）或 `single`（只有最新一句）。
    var resultType: String
    /// 二遍识别。
    var nonstream: Bool
    var hotwords: [String]
}

enum VolcServerMessage {
    case result(ASRResult?, isLast: Bool)
    case error(code: UInt32, message: String)
    case unknown
}

/// 火山引擎大模型流式识别的二进制帧：4 字节头 + 4 字节大端长度 + payload。
/// 客户端一律不压缩、音频包不带序列号，服务端会按同样的方式回包。
enum VolcProtocol {
    static let sampleRate = 16000
    static let bytesPerMs = sampleRate * 2 / 1000

    static func fullClientRequest(_ json: Data) -> Data {
        var frame = Data(capacity: 8 + json.count)
        frame.append(contentsOf: [0x11, 0x10, 0x10, 0x00] as [UInt8])
        appendSize(&frame, json.count)
        frame.append(json)
        return frame
    }

    static func audioRequest(_ pcm: Data, last: Bool) -> Data {
        var frame = Data(capacity: 8 + pcm.count)
        frame.append(contentsOf: [0x11, last ? 0x22 : 0x20, 0x00, 0x00] as [UInt8])
        appendSize(&frame, pcm.count)
        frame.append(pcm)
        return frame
    }

    /// 在热词或设置变化时预先生成，按键时直接发送。
    /// `context` 是最近几句上屏文本（从新到旧），会作为对话上下文一起发给识别服务。
    static func requestJSON(_ options: ASROptions, context: [String] = []) -> Data {
        var request: [String: Any] = [
            "model_name": options.modelName,
            "enable_itn": options.itn,
            "enable_punc": options.punc,
            "enable_ddc": options.ddc,
            "show_utterances": true,
            "result_type": options.resultType,
        ]
        if options.endWindowMs >= 200 { request["end_window_size"] = options.endWindowMs }
        if options.forceToSpeechMs > 0 { request["force_to_speech_time"] = options.forceToSpeechMs }
        if options.nonstream { request["enable_nonstream"] = true }

        // 服务端的热词上限是 100 token（双向流式）/ 5000 词（二遍链路）。
        // 按字符数做宽松截断：英文单词一个词往往只占 1 个 token，按字算会把尾部全砍掉，
        // 真正超了由服务端自己按 token 截断。
        var budget = 400
        var words: [[String: String]] = []
        for word in options.hotwords {
            let cost = word.count
            guard cost > 0, cost <= budget else { continue }
            budget -= cost
            words.append(["word": word])
        }
        if !words.isEmpty || !context.isEmpty {
            var corpus: [String: Any] = [:]
            if !words.isEmpty { corpus["hotwords"] = words }
            if !context.isEmpty {
                corpus["context_type"] = "dialog_ctx"
                corpus["context_data"] = context.map { ["text": $0] }
            }
            if let data = try? JSONSerialization.data(withJSONObject: corpus),
               let string = String(data: data, encoding: .utf8) {
                request["corpus"] = ["context": string]
            }
        }

        let root: [String: Any] = [
            "user": ["uid": "daxiangshuo-mac"],
            "audio": ["format": "pcm", "codec": "raw", "rate": options.sampleRate, "bits": 16, "channel": 1],
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    static func parse(_ data: Data) -> VolcServerMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .unknown }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        var i = headerSize

        switch type {
        case 0b1001:
            var isLast = flags & 0b0010 != 0
            if flags & 0b0001 != 0 {
                guard let seq = readUInt32(bytes, &i) else { return .unknown }
                if Int32(bitPattern: seq) < 0 { isLast = true }
            }
            guard let size = readUInt32(bytes, &i), i + Int(size) <= bytes.count else {
                return .result(nil, isLast: isLast)
            }
            var payload = Data(bytes[i..<(i + Int(size))])
            if compression == 1, let raw = gunzip(payload) { payload = raw }
            return .result(parseResult(payload), isLast: isLast)

        case 0b1111:
            guard let code = readUInt32(bytes, &i) else { return .unknown }
            var message = ""
            if let size = readUInt32(bytes, &i), i + Int(size) <= bytes.count {
                var payload = Data(bytes[i..<(i + Int(size))])
                if compression == 1, let raw = gunzip(payload) { payload = raw }
                message = String(decoding: payload, as: UTF8.self)
            }
            return .error(code: code, message: message)

        default:
            return .unknown
        }
    }

    static func describe(code: UInt32, message: String) -> String {
        let meaning: String
        switch code {
        case 45000001: meaning = "请求参数无效"
        case 45000002: meaning = "空音频"
        case 45000081: meaning = "等包超时"
        case 45000151: meaning = "音频格式不正确"
        case 55000031: meaning = "服务器繁忙"
        default: meaning = code / 100000 == 550 ? "服务内部错误" : "识别出错"
        }
        return "\(meaning)（\(code)）"
    }

    // MARK: 私有

    private static func parseResult(_ payload: Data) -> ASRResult? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        var resultObject = root["result"] as? [String: Any]
        if resultObject == nil, let list = root["result"] as? [[String: Any]] { resultObject = list.first }
        guard let result = resultObject else { return nil }
        let text = result["text"] as? String ?? ""
        let utterances = (result["utterances"] as? [[String: Any]] ?? []).map {
            ASRUtterance(text: $0["text"] as? String ?? "", definite: $0["definite"] as? Bool ?? false)
        }
        return ASRResult(text: text, utterances: utterances)
    }

    private static func appendSize(_ data: inout Data, _ size: Int) {
        let be = UInt32(size).bigEndian
        withUnsafeBytes(of: be) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        i += 4
        return v
    }

    /// 只在服务端意外返回 gzip 时使用：跳过 gzip 头，用系统 Compression 解 raw deflate。
    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        let flg = bytes[3]
        var i = 10
        if flg & 0x04 != 0, i + 2 <= bytes.count { i += 2 + Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        if flg & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x02 != 0 { i += 2 }
        guard i < bytes.count - 8 else { return nil }
        let n = bytes.count
        let expected = Int(bytes[n - 4]) | Int(bytes[n - 3]) << 8 | Int(bytes[n - 2]) << 16 | Int(bytes[n - 1]) << 24
        let capacity = max(expected, 1024)
        var out = [UInt8](repeating: 0, count: capacity)
        let written = bytes[i..<(n - 8)].withContiguousStorageIfAvailable { src in
            compression_decode_buffer(&out, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        } ?? 0
        return written > 0 ? Data(out[0..<written]) : nil
    }
}
