import Foundation
import Observation

enum PhraseKind: Int, Codable, CaseIterable, Identifiable {
    /// 热词：提高识别率，同时作为术语表发给大模型。
    case hotword = 0
    /// 替换规则：说出 trigger，上屏 value。
    case replacement = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hotword: "热词"
        case .replacement: "替换规则"
        }
    }
}

struct Phrase: Identifiable, Codable, Hashable {
    var id: Int64
    var kind: PhraseKind
    var trigger: String
    var value: String
}

@Observable
final class PhraseStore {
    static let shared = PhraseStore()

    private(set) var items: [Phrase] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let db = Database.shared

    private init() {
        reload()
    }

    var hotwords: [String] {
        items.filter { $0.kind == .hotword }.map(\.trigger)
    }

    var replacements: [(String, String)] {
        items.filter { $0.kind == .replacement && !$0.trigger.isEmpty }.map { ($0.trigger, $0.value) }
    }

    func items(of kind: PhraseKind) -> [Phrase] {
        items.filter { $0.kind == kind }
    }

    func add(kind: PhraseKind, trigger: String, value: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return }
        db.execute("INSERT INTO phrases (kind, term, value, created) VALUES (?, ?, ?, ?)",
                   [.int(Int64(kind.rawValue)), .text(trigger), .text(value), .double(Date().timeIntervalSince1970)])
        changed()
    }

    func update(_ phrase: Phrase) {
        db.execute("UPDATE phrases SET term = ?, value = ? WHERE id = ?",
                   [.text(phrase.trigger.trimmingCharacters(in: .whitespacesAndNewlines)),
                    .text(phrase.value), .int(phrase.id)])
        changed()
    }

    func delete(_ phrase: Phrase) {
        db.execute("DELETE FROM phrases WHERE id = ?", [.int(phrase.id)])
        changed()
    }

    // MARK: 导入导出

    private struct ExportItem: Codable {
        var kind: PhraseKind
        var trigger: String
        var value: String
    }

    func exportJSON() throws -> Data {
        let list = items.map { ExportItem(kind: $0.kind, trigger: $0.trigger, value: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(list)
    }

    /// 返回导入条数；已存在的相同条目会跳过。
    func importJSON(_ data: Data) throws -> Int {
        let list = try JSONDecoder().decode([ExportItem].self, from: data)
        let existing = Set(items.map { "\($0.kind.rawValue)|\($0.trigger)" })
        var count = 0
        for item in list where !existing.contains("\(item.kind.rawValue)|\(item.trigger)") {
            let trigger = item.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            db.execute("INSERT INTO phrases (kind, term, value, created) VALUES (?, ?, ?, ?)",
                       [.int(Int64(item.kind.rawValue)), .text(trigger), .text(item.value),
                        .double(Date().timeIntervalSince1970)])
            count += 1
        }
        changed()
        return count
    }

    private func reload() {
        items = db.query("SELECT id, kind, term, value FROM phrases ORDER BY created DESC") { row in
            Phrase(id: row.int(0), kind: PhraseKind(rawValue: Int(row.int(1))) ?? .hotword,
                   trigger: row.text(2), value: row.text(3))
        }
    }

    private func changed() {
        reload()
        onChange?()
    }
}
