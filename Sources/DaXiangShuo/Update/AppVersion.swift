import Foundation

/// 语义化版本号（只比较 major.minor.patch）。预发布后缀（如 `-beta.1`）不参与比较：
/// 发版时稳定版永远比同号的预发布版大，而客户端只认 stable 渠道。
struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    private let raw: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 -beta / +build 之类的尾巴，只留数字部分。
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = trimmed
    }

    var description: String { raw }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
