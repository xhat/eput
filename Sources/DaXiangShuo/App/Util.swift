import Darwin
import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "com.andy.daxiangshuo", category: "app")
    static let asr = Logger(subsystem: "com.andy.daxiangshuo", category: "asr")
    static let audio = Logger(subsystem: "com.andy.daxiangshuo", category: "audio")
    static let latency = Logger(subsystem: "com.andy.daxiangshuo", category: "latency")
    static let update = Logger(subsystem: "com.andy.daxiangshuo", category: "update")
}

/// mach_absolute_time 与毫秒之间的换算；音频时间戳和按键时刻都用这个时钟。
enum HostTime {
    static let nsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    @inline(__always) static func now() -> UInt64 { mach_absolute_time() }

    @inline(__always) static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * nsPerTick / 1_000_000_000
    }

    @inline(__always) static func ticks(ms: Double) -> UInt64 {
        UInt64(ms * 1_000_000 / nsPerTick)
    }

    static func ms(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) * nsPerTick / 1_000_000
    }
}

/// 轻量互斥锁，临界区只做内存拷贝，可以在音频实时线程中使用。
final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(pointer) }

    @inline(__always) func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}

/// 项目对外的网址，统一放这里，界面、关于面板、统计上报都从这里取。
enum AppLinks {
    static let website = URL(string: "https://eput.ruoxie.com/")!
    static let github = URL(string: "https://github.com/xhat/eput")!
    static let launchAPI = URL(string: "api/launch", relativeTo: website)!.absoluteURL
}
