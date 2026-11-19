import Carbon

/// 拼音等输入法会截获合成按键。听写期间临时切到英文键盘布局，结束后切回。
/// 只能在主线程调用。
final class InputSourceGuard {
    private var saved: TISInputSource?

    func switchToASCIIIfNeeded() {
        guard saved == nil,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(current, kTISPropertyInputSourceType) else { return }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        guard type != (kTISTypeKeyboardLayout as String),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        if TISSelectInputSource(ascii) == noErr {
            saved = current
        }
    }

    func restore() {
        guard let source = saved else { return }
        saved = nil
        TISSelectInputSource(source)
    }
}
