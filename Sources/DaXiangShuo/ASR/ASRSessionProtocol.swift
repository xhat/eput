import Foundation

/// 一次听写的识别会话。火山引擎走双向流式 WebSocket，DeepSeek 是整段上传，两者都实现这套接口。
protocol ASRSessionProtocol: AnyObject {
    /// 是否支持边说边出字。DeepSeek 整段识别，只能说完再一次性上屏。
    var supportsLiveTyping: Bool { get }
    func start()
    func sendAudio(_ pcm: Data)
    func finish(tail: Data)
    func cancel()
}

enum ASREvent {
    case result(ASRResult)
    case failed(String)
    case finished
}
