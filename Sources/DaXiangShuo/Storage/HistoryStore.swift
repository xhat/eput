import Foundation
import Observation

struct HistoryItem: Identifiable, Hashable {
    let id: Int64
    let created: Date
    let duration: Double
    let raw: String
    let text: String
    let app: String
}

@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var items: [HistoryItem] = []
    private(set) var todayChars = 0
    private(set) var totalCount = 0
    var search = "" { didSet { reload() } }

    @ObservationIgnored private let db = Database.shared
    /// 只有打开历史记录页时才把记录读进内存，窗口关闭后释放。
    @ObservationIgnored private var itemsLoaded = false

    private init() {
        refreshStats()
    }

    func unloadItems() {
        itemsLoaded = false
        items = []
    }

    func reload() {
        itemsLoaded = true
        let keyword = search.trimmingCharacters(in: .whitespaces)
        let columns = "SELECT id, created, duration, raw, text, app FROM history"
        let map: (SQLRow) -> HistoryItem = { row in
            HistoryItem(id: row.int(0), created: Date(timeIntervalSince1970: row.double(1)),
                        duration: row.double(2), raw: row.text(3), text: row.text(4), app: row.text(5))
        }
        if keyword.isEmpty {
            items = db.query("\(columns) ORDER BY created DESC LIMIT 1000", map: map)
        } else {
            let like = SQLValue.text("%\(keyword)%")
            items = db.query("\(columns) WHERE text LIKE ?1 OR raw LIKE ?1 OR app LIKE ?1 ORDER BY created DESC LIMIT 1000",
                             [like], map: map)
        }
        refreshStats()
    }

    private func refreshStats() {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        todayChars = Int(db.query("SELECT COALESCE(SUM(LENGTH(text)), 0) FROM history WHERE created >= ?",
                                  [.double(startOfDay)]) { $0.int(0) }.first ?? 0)
        totalCount = Int(db.query("SELECT COUNT(*) FROM history") { $0.int(0) }.first ?? 0)
    }

    /// 最近几句整理后的正文（含正确的英文写法），给 ASR 的上下文用。
    func recentTexts(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return db.query("SELECT text FROM history ORDER BY created DESC LIMIT ?", [.int(Int64(limit))]) {
            $0.text(0)
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    func add(raw: String, text: String, duration: Double, app: String) {
        db.execute("INSERT INTO history (created, duration, raw, text, app) VALUES (?, ?, ?, ?, ?)",
                   [.double(Date().timeIntervalSince1970), .double(duration), .text(raw), .text(text), .text(app)])
        if itemsLoaded { reload() } else { refreshStats() }
    }

    func delete(_ item: HistoryItem) {
        db.execute("DELETE FROM history WHERE id = ?", [.int(item.id)])
        reload()
    }

    func clear() {
        db.execute("DELETE FROM history")
        reload()
    }
}
