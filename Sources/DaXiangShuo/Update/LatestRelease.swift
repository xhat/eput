import Foundation

/// 大象说检查更新时唯一认的地址。写死在这里：能被运行时改掉的更新地址都是攻击面，
/// 只有调试用的 `DAXIANGSHUO_UPDATE_API_BASE` 可以临时指到本机。
enum VersionAPI {
    static let product = "daxiangshuo"
    static let baseURL = URL(string: "https://version.ruoxie.com")!

    /// `GET /api/daxiangshuo`：最新稳定版，以及每个平台的下载地址、大小和 SHA-256。公开接口，不带令牌。
    static var latestURL: URL {
        baseURL.appending(path: "api/\(product)")
    }

    /// 服务端把架构叫 arm / x86，本项目只出 arm64 包。
    static var platform: String { "arm" }
}

/// `GET https://version.ruoxie.com/api/daxiangshuo` 的返回体。
/// 没有任何版本时也返回同样结构（`version: null`、`assets` 为空），解码不用猜。
struct LatestReleaseDocument: Decodable, Sendable {
    let version: String?
    let channel: String?
    let changelog: String?
    let publishedAt: String?
    /// 平台 → 下载地址，没有校验和，只作兜底。
    let packages: [String: URL]
    /// 平台 → 文件名 / 大小 / sha256 / 地址。更新必须用它，没校验和的包不能装。
    let assets: [String: ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case version, channel, changelog, packages, assets
        case publishedAt = "published_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        changelog = try container.decodeIfPresent(String.self, forKey: .changelog)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        packages = (try? container.decodeIfPresent([String: URL].self, forKey: .packages)) ?? [:]
        assets = (try? container.decodeIfPresent([String: ReleaseAsset].self, forKey: .assets)) ?? [:]
    }

    /// 只有同时给出「版本号」和「本架构的 SHA-256」才算一个可用的版本。
    func release(for platform: String) -> AppRelease? {
        guard let version, !version.isEmpty, let asset = assets[platform] else { return nil }
        return AppRelease(version: version, channel: channel,
                          changelog: changelog?.updateNote, publishedAt: publishedAt,
                          asset: asset)
    }
}

struct ReleaseAsset: Decodable, Equatable, Sendable {
    let filename: String?
    let size: Int64?
    let sha256: String
    let url: URL
}

/// 一个可安装的版本：版本号 + 已发布的安装包。
struct AppRelease: Equatable, Sendable {
    let version: String
    let channel: String?
    let changelog: String?
    let publishedAt: String?
    let asset: ReleaseAsset

    /// 带版本号的永久地址，重试时不必重新解析「最新版本」。
    var url: URL { asset.url }
    var sha256: String { asset.sha256 }
    var size: Int64? { asset.size }
    /// 发布说明，用作提示文字。
    var notes: String? { changelog }
}

private extension String {
    /// 空白的 changelog 当成没有。
    var updateNote: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
