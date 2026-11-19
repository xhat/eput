import AppKit
import CryptoKit
import Foundation
import IOKit

/// 匿名启动统计：每次打开应用都在一分钟内随机上报一次（event = launch，服务端每次都记，不去重）；
/// 之后运行期间，每天上午和下午各在一个随机时间点再上报一次（event = daily，只刷新活跃时间，不算启动）。
/// 只读系统信息，不做任何计算；失败静默忽略，不重试，绝不影响正常使用。
/// 内容不含：序列号、MAC、用户名、电脑名、API Key、历史记录、词典内容、录音。
@MainActor
enum LaunchReporter {
    private nonisolated static let endpoint = AppLinks.launchAPI
    /// 启动后多少秒内随机上报，避免每次一启动就立刻发请求。
    private static let delayRange: ClosedRange<Double> = 5...60
    /// 每天的两个上报时段（本地时间，小时）：上午 9–12 点、下午 13–18 点，各随机挑一个时间点。
    static let dailyWindows: [(from: Int, to: Int)] = [(9, 12), (13, 18)]

    private static var settings: AppSettings?
    private static var timer: Timer?
    /// 当天还没到的上报时间点（升序）。用完后再生成下一天的。
    private static var pending: [Date] = []

    static func start(settings: AppSettings) {
        #if !DEBUG
        self.settings = settings
        let delay = Double.random(in: delayRange)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            report(event: "launch")
            scheduleNext()
        }
        #endif
    }

    /// 定时器按墙上时间触发；电脑睡眠错过了时间点，醒来后会很快补发，然后接着排下一个。
    private static func scheduleNext(now: Date = Date()) {
        if pending.isEmpty { pending = plan(now: now) }
        guard let next = pending.first else { return }
        timer?.invalidate()
        let t = Timer(fire: next, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !pending.isEmpty { pending.removeFirst() }
                report(event: "daily")
                scheduleNext()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 生成当天剩余的时间点；当天都过了就生成明天的。已经过了一半的时段只在剩下的部分里随机。
    static func plan(now: Date, calendar: Calendar = .current) -> [Date] {
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            var points: [Date] = []
            for window in dailyWindows {
                guard let start = calendar.date(byAdding: .hour, value: window.from, to: day),
                      let end = calendar.date(byAdding: .hour, value: window.to, to: day) else { continue }
                let lower = max(start, now.addingTimeInterval(60))
                guard lower < end else { continue }
                points.append(Date(timeIntervalSince1970: .random(in: lower.timeIntervalSince1970..<end.timeIntervalSince1970)))
            }
            if !points.isEmpty { return points.sorted() }
        }
        return []
    }

    private static func report(event: String) {
        guard let settings else { return }
        var body = payload(settings: settings)
        body["event"] = event
        Task.detached(priority: .background) { await send(body) }
    }

    // MARK: 内容

    private static func payload(settings: AppSettings) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var body: [String: Any] = [
            "install_id": installID(),
            "app_version": String((info?["CFBundleShortVersionString"] as? String ?? "").prefix(32)),
            "os_version": String(osVersion().prefix(64)),
        ]

        // 系统和设备（内存、硬盘容量）
        body["app_build"] = info?["CFBundleVersion"] as? String ?? ""
        body["os_build"] = sysctlString("kern.osversion")
        body["arch"] = sysctlString("hw.machine")
        body["model"] = sysctlString("hw.model")
        body["cpu_cores"] = ProcessInfo.processInfo.processorCount
        body["memory_gb"] = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        if let disk = diskCapacityGB() { body["disk_gb"] = disk }

        // 屏幕
        if let screen = NSScreen.main {
            body["screen"] = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
            body["scale"] = Int(screen.backingScaleFactor)
        }
        body["screen_count"] = NSScreen.screens.count

        // 环境
        body["language"] = Locale.preferredLanguages.first ?? ""
        body["timezone"] = TimeZone.current.identifier

        // 使用偏好（只有开关状态，没有任何内容）
        body["trigger_mode"] = settings.hotkeyMode.rawValue
        body["llm_enabled"] = settings.llmEnabled
        body["two_pass"] = settings.asrNonstream
        body["output_mode"] = settings.typingMode.rawValue
        return body
    }

    /// 基于硬件的匿名 ID：机器的硬件 UUID 加上本应用专用的盐做 SHA-256，再排成 UUID 格式。
    /// 原始硬件 UUID 不会离开本机，也无法从这个 ID 反推。读取失败时退回一个随机 UUID（存在偏好里，之后沿用）。
    private static func installID() -> String {
        if let hardware = hardwareUUID() {
            let digest = SHA256.hash(data: Data("com.andy.daxiangshuo|\(hardware)".utf8))
            var bytes = Array(digest.prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50   // 版本位：基于哈希的 UUID
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                .uuidString.lowercased()
        }
        let key = "fallbackInstallID"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// 系统盘总容量，单位 GB（按 1 GB = 10⁹ 字节，和「关于本机」里显示的一致，例如 500、1000）。
    private static func diskCapacityGB() -> Int? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        guard let bytes = values?.volumeTotalCapacity, bytes > 0 else { return nil }
        return Int((Double(bytes) / 1_000_000_000).rounded())
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                  : "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    // MARK: 发送

    private nonisolated static func send(_ body: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        _ = try? await URLSession(configuration: config).data(for: request)
    }
}
