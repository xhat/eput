import Foundation
import Observation

/// 语音识别按音频时长计费，这里记录每天实际发给识别服务的音频秒数。
/// 用量单独存表，清空历史记录不会影响它。
@Observable
final class UsageStore {
    static let shared = UsageStore()

    /// 火山引擎豆包流式语音识别的默认免费额度（秒）。
    static let freeQuotaSeconds: Double = 20 * 3600

    struct Day: Identifiable {
        let id: String
        let date: Date
        let seconds: Double
    }

    /// 过去 7 天（含今天），按日期从早到晚。
    private(set) var last7Days: [Day] = []
    /// 过去 30 天（含今天）的合计。
    private(set) var last30Seconds: Double = 0
    /// 统计开始以来的累计。
    private(set) var totalSeconds: Double = 0
    /// 本次打开软件以来的累计。
    private(set) var sinceLaunchSeconds: Double = 0

    @ObservationIgnored private let db = Database.shared
    @ObservationIgnored private var loaded = false

    private init() {
        seedFromHistoryIfNeeded()
    }

    /// 一次听写结束后调用，seconds 是这次发给识别服务的音频时长。
    func record(seconds: Double) {
        guard seconds > 0 else { return }
        DispatchQueue.main.async {
            self.sinceLaunchSeconds += seconds
            self.db.execute("""
                INSERT INTO usage (day, seconds) VALUES (?, ?)
                ON CONFLICT(day) DO UPDATE SET seconds = seconds + excluded.seconds
                """, [.text(Self.dayKey(Date())), .double(seconds)])
            if self.loaded { self.reload() }
        }
    }

    /// 打开统计页时读取，窗口关闭后 unload 释放。
    func reload() {
        loaded = true
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let rows = db.query("SELECT day, seconds FROM usage WHERE day >= ?", [.text(Self.dayKey(start30))]) {
            ($0.text(0), $0.double(1))
        }
        let byDay = Dictionary(rows, uniquingKeysWith: +)
        last30Seconds = rows.reduce(0) { $0 + $1.1 }
        last7Days = (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = Self.dayKey(date)
            return Day(id: key, date: date, seconds: byDay[key] ?? 0)
        }
        totalSeconds = db.query("SELECT COALESCE(SUM(seconds), 0) FROM usage") { $0.double(0) }.first ?? 0
    }

    func unload() {
        loaded = false
        last7Days = []
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 第一次带有用量统计的版本启动时，用已有的历史记录估算之前的用量（按每条的按键时长累加）。
    private func seedFromHistoryIfNeeded() {
        let key = "usageSeededFromHistory"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        db.execute("""
            INSERT OR IGNORE INTO usage (day, seconds)
            SELECT strftime('%Y-%m-%d', created, 'unixepoch', 'localtime'), SUM(duration)
            FROM history GROUP BY 1
            """)
    }
}
