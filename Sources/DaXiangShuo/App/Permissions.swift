import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestMicrophoneIfNeeded(_ done: ((Bool) -> Void)? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done?(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done?(ok) }
            }
        default:
            done?(false)
        }
    }

    /// 系统只有一个用途：把「大象说」加进辅助功能列表。这件事只做一次——
    /// 每次启动都弹窗口很烦，而且真正需要重复授权的那个老问题（升级后授权失效）
    /// 已经靠固定签名身份解决了。
    private static let promptedKey = "hasPromptedAccessibility"

    /// 返回是否真的弹了系统提示。之前弹过、用户还没授权时返回 false，
    /// 由调用方改用界面里的安静提示。
    @discardableResult
    static func promptAccessibilityIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return false }
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return false }
        UserDefaults.standard.set(true, forKey: promptedKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return true
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// 没有输入设备时，直接把入声音设置。
    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
