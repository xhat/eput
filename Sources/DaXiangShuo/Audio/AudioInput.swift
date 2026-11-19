import CoreAudio
import Foundation

/// 用 CoreAudio HAL 查询系统当前的默认输入设备。
///
/// 必须在碰 AVAudioEngine 之前先问这里：机器上没有任何输入设备时，
/// AVAudioEngine 会在 `connect(_:to:format:)` 里抛 Objective-C 异常，
/// Swift 层接不住，进程被直接 abort，系统随即弹出崩溃报告。
enum AudioInput {
    struct Device: Equatable {
        let name: String
        let sampleRate: Double
        let channels: Int
    }

    enum Status: Equatable {
        /// 有可用的输入设备。
        case ready(Device)
        /// 系统里没有任何输入设备：机器本身没有麦克风，也没有插外接麦克风。
        case noDevice
        /// 设备在，但没有输入声道（纯输出的声卡、被接管的虚拟设备等）。
        case noChannels(Device)

        var device: Device? {
            if case .ready(let device) = self { return device }
            return nil
        }

        var isReady: Bool { device != nil }
    }

    static func current() -> Status {
        guard let id = defaultDevice() else { return .noDevice }
        let device = Device(name: name(of: id),
                            sampleRate: sampleRate(of: id),
                            channels: inputChannels(of: id))
        return device.channels > 0 ? .ready(device) : .noChannels(device)
    }

    // MARK: 私有

    private static func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &address, 0, nil, &size, &device)
        guard result == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func sampleRate(of device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard result == noErr, size > 0 else { return "声音输入设备" }
        let name = value as String
        return name.isEmpty ? "声音输入设备" : name
    }
}
