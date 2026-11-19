import AppKit
import CryptoKit
import Foundation
import Observation

/// 检查 `GET https://version.ruoxie.com/api/daxiangshuo`，把新版本下好、校验、解开，
/// 用户点一下再替换。
///
/// 隐私：检查更新只是一个匿名的 GET，不带安装 ID、不带任何设备信息。
///
/// 检查时机：
/// - 每次打开主界面查一次，但 10 分钟内查过就不重复查（频繁开关窗口不会一直打服务端）；
/// - 其余情况每天最多自动查一次，时间落在本机时间 04:00–05:00 之间的某个随机时刻
///   （错过——比如机器休眠——醒来后补一次）。
/// 发现新版本就立刻下载、校验 SHA-256、解到临时目录。是否安装始终由用户决定——
/// 主界面左下角的「升级」按钮是唯一入口。
/// 替换本身交给一个脱离本进程的 `/bin/sh` 脚本，因为运行中的 app 没法替换自己。
@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// 已发现新版本，正在下载 / 校验 / 解包。这个状态下什么都还没装。
        case downloading
        /// 校验通过、解包完成，等用户点一下。
        case ready
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// 校验通过的新版本，只有发现更新后才不为 nil。
    private(set) var release: AppRelease?
    /// 用户主动检查失败时的原因。后台失败保持安静。
    private(set) var lastError: String?

    /// 当前正在运行的版本号，例如 `1.0.1`。
    var currentVersion: String { Self.bundleVersion?.description ?? "—" }

    var isBusy: Bool {
        state == .checking || state == .downloading || state == .installing
    }

    /// 已经准备好，一次点击就能换上。
    var isPrepared: Bool {
        state == .ready && preparedApplication != nil
    }

    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private var hasStarted = false
    /// 上一次真的发出请求的时间：打开界面时的 10 分钟去重看它。
    @ObservationIgnored private var lastCheckAt: Date?
    /// 上一次「每天那一查」的时间，避免同一天重复触发。
    @ObservationIgnored private var lastDailyCheckAt: Date?
    /// 每天那一次检查的定时器。
    @ObservationIgnored private var dailyTimer: Task<Void, Never>?
    /// 打开界面时，距上次检查不到这么久就跳过。
    private static let windowOpenDebounce: TimeInterval = 10 * 60
    /// 已解包、待安装的 app，以及它所在的临时目录。
    @ObservationIgnored private var preparedApplication: URL?
    @ObservationIgnored private var staging: URL?
    /// 后台解包留下的旧目录，超过这个时间就删掉。
    @ObservationIgnored private let staleStagingAge: TimeInterval = 24 * 60 * 60
    /// 下载还没结束用户就点了：校验一过立刻安装，不让用户再点一次。
    @ObservationIgnored private var pendingApply = false
    @ObservationIgnored private var preparation: Task<Void, Never>?
    /// 调试用：解包完成后自动安装，便于无界面地把整条链路跑一遍。
    @ObservationIgnored private let autoApply: Bool

    init() {
        autoApply = ProcessInfo.processInfo.environment["DAXIANGSHUO_UPDATE_AUTO_APPLY"] == "1"
    }

    /// 启动时调用一次：只排「每天 04:00–05:00 随机时刻」那一次。
    /// 打开主界面会另外触发一次（见 `checkOnWindowOpen`）。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Self.pruneStaleStaging(olderThan: staleStagingAge)
        scheduleDaily()
    }

    /// 每次打开主界面调用：10 分钟内查过就不再查。
    func checkOnWindowOpen() {
        if let last = lastCheckAt, Date().timeIntervalSince(last) < Self.windowOpenDebounce { return }
        Task { [weak self] in await self?.check(manual: false) }
    }

    /// 每天的自动检查：定在 04:00–05:00 之间随机一个时刻。
    private func scheduleDaily() {
        dailyTimer?.cancel()
        let fire = Self.nextDailyFire(after: Date())
        let delay = max(30, fire.timeIntervalSinceNow)
        Log.update.notice("下次自动检查更新：\(fire.formatted(date: .abbreviated, time: .shortened), privacy: .public)")
        dailyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.runDailyCheck()
        }
    }

    private func runDailyCheck() async {
        // 今天已经查过（比如窗口刚打开查过一次）就不再打一遍服务端。
        if let last = lastDailyCheckAt, Calendar.current.isDateInToday(last) {
            scheduleDaily()
            return
        }
        await check(manual: false)
        lastDailyCheckAt = Date()
        scheduleDaily()
    }

    /// 下一次「每天那一查」的时刻：今天 04:00–05:00 里的随机一秒，已经过了就用明天的。
    nonisolated static func nextDailyFire(after now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let offset = TimeInterval(4 * 3600 + Int.random(in: 0..<3600))
        let fire = today.addingTimeInterval(offset)
        return fire > now ? fire : today.addingTimeInterval(24 * 3600 + offset)
    }

    /// 问服务端要最新版本。用户主动点的会显示失败原因；后台检查静默，
    /// 也不会因为一次失败就把已经下好的包丢掉。
    func check(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        let previous = state
        lastCheckAt = Date()
        if previous != .ready { state = .checking }
        if manual { lastError = nil }

        do {
            guard let current = Self.bundleVersion else { throw UpdateFailure.notBundled }
            guard let fetched = try await fetchLatest() else {
                Log.update.notice("没有已发布的版本")
                settleWithoutNewer(manual: manual)
                return
            }
            guard let candidate = AppVersion(fetched.version), candidate > current else {
                Log.update.notice("已是最新版本 \(current.description, privacy: .public)")
                settleWithoutNewer(manual: manual)
                return
            }
            if release?.version == fetched.version, preparedApplication != nil {
                Log.update.notice("\(fetched.version, privacy: .public) 已经准备好")
                state = .ready
                return
            }

            Log.update.notice("发现新版本 \(fetched.version, privacy: .public)")
            discardPrepared()
            release = fetched
            beginPreparation(fetched)
        } catch {
            let failure = error as? UpdateFailure ?? .network
            Log.update.error("检查更新失败：\(failure.key, privacy: .public)")
            if manual {
                lastError = failure.message
                state = .failed(failure.message)
            } else if preparedApplication != nil {
                state = .ready
            } else {
                state = .idle
            }
        }
    }

    /// 服务端没有更新的版本。缺版本不等于撤回：不删已下好的包，只有被更新的版本取代才换。
    private func settleWithoutNewer(manual: Bool) {
        if preparedApplication != nil {
            state = .ready
            return
        }
        release = nil
        state = manual ? .upToDate : .idle
    }

    // MARK: 准备

    private func beginPreparation(_ release: AppRelease) {
        state = .downloading
        preparation = Task { [weak self] in
            await self?.prepare(release)
        }
    }

    /// 下载、校验、解包。这里绝不替换 app，`install()` 才是唯一的替换入口。
    private func prepare(_ intended: AppRelease) async {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "DaXiangShuoUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let archive = staging.appending(path: "DaXiangShuo-\(intended.version).zip")
            try await download(intended.url, to: archive)
            guard try Self.sha256(of: archive) == intended.sha256 else { throw UpdateFailure.checksum }

            let extractDirectory = staging.appending(path: "Extracted", directoryHint: .isDirectory)
            try Self.extract(archive, to: extractDirectory)
            guard let application = Self.findApplication(in: extractDirectory) else {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: extractDirectory.path)) ?? []
                Log.update.error("解包目录里找不到 .app：\(names.joined(separator: ","), privacy: .public)")
                throw UpdateFailure.extract
            }
            guard Self.bundleVersion(at: application) == AppVersion(intended.version) else {
                throw UpdateFailure.versionMismatch
            }

            // 下载期间可能又发现了一个更新的版本，这一份就作废。
            guard release?.version == intended.version else {
                try? FileManager.default.removeItem(at: staging)
                Log.update.notice("\(intended.version, privacy: .public) 已被更新的版本取代")
                return
            }

            preparedApplication = application
            self.staging = staging
            state = .ready
            Log.update.notice("\(intended.version, privacy: .public) 已下载并校验通过")

            if pendingApply || autoApply {
                applyPrepared()
            }
        } catch {
            let failure = error as? UpdateFailure ?? .download
            Log.update.error("准备 \(intended.version, privacy: .public) 失败：\(failure.key, privacy: .public)")
            try? FileManager.default.removeItem(at: staging)
            guard release?.version == intended.version else { return }
            preparedApplication = nil
            self.staging = nil
            if pendingApply {
                pendingApply = false
                lastError = failure.message
                state = .failed(failure.message)
            } else {
                // 后台准备失败不打扰用户，下一次检查重试。
                state = .idle
            }
        }
    }

    // MARK: 安装

    /// 换上准备好的版本。还在下载时点的话，校验一通过就自动安装，不会重复下载。
    func install() async {
        if preparedApplication != nil {
            switch state {
            case .checking, .downloading:
                pendingApply = true
            case .installing:
                return
            default:
                applyPrepared()
            }
            return
        }
        switch state {
        case .checking, .downloading:
            pendingApply = true
        case .installing:
            return
        default:
            guard let release else {
                await check(manual: true)
                return
            }
            pendingApply = true
            beginPreparation(release)
        }
    }

    /// 把解好的 app 交给一个能活过本进程的脚本，然后退出。只有脚本起来了才退出。
    private func applyPrepared() {
        pendingApply = false
        guard let release, let application = preparedApplication, let staging else { return }
        do {
            try launchHelper(newApplication: application, staging: staging)
            state = .installing
            Log.update.notice("已启动替换脚本，退出后安装 \(release.version, privacy: .public)")
            NSApp.terminate(nil)
        } catch {
            let failure = error as? UpdateFailure ?? .helper
            Log.update.error("安装失败：\(failure.key, privacy: .public)")
            lastError = failure.message
            state = .failed(failure.message)
        }
    }

    /// 丢掉准备好的包，只删临时目录，绝不动 app。
    private func discardPrepared() {
        preparation?.cancel()
        preparation = nil
        pendingApply = false
        if let staging {
            try? FileManager.default.removeItem(at: staging)
        }
        staging = nil
        preparedApplication = nil
    }

    /// 清掉上次崩溃或下载到一半就退出留下的目录；新的目录可能是另一个进程的，不动。
    private static func pruneStaleStaging(olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for entry in entries where entry.lastPathComponent.hasPrefix("DaXiangShuoUpdate-") {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            throw UpdateFailure.download
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateFailure.download
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw UpdateFailure.download
        }
    }

    /// 用 `/bin/sh 脚本 参数…` 启动替换脚本，完全脱离本进程。
    /// 路径全部走参数，所以带空格的目录名不用在本文件里处理引号。
    private func launchHelper(newApplication: URL, staging: URL) throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              !bundle.path.contains("/AppTranslocation/")
        else { throw UpdateFailure.location }

        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateFailure.location
        }

        let script = FileManager.default.temporaryDirectory
            .appending(path: "daxiangshuo-update-\(UUID().uuidString).sh")
        do {
            try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            throw UpdateFailure.helper
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            bundle.path,
            newApplication.path,
            staging.path,
            script.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw UpdateFailure.helper
        }
    }

    // MARK: 网络

    private func fetchLatest() async throws -> AppRelease? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateFailure.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateFailure.network
        }

        let document: LatestReleaseDocument
        do {
            document = try JSONDecoder().decode(LatestReleaseDocument.self, from: data)
        } catch {
            throw UpdateFailure.invalidResponse
        }
        guard let release = document.release(for: VersionAPI.platform) else { return nil }
        try Self.validate(release)
        return release
    }

    private static func validate(_ release: AppRelease) throws {
        guard AppVersion(release.version) != nil else { throw UpdateFailure.invalidResponse }

        let scheme = release.url.scheme?.lowercased()
        // 本机 mock 是唯一例外，方便走一遍整条链路。
        let localTesting = scheme == "http" && apiBaseOverride != nil
        guard scheme == "https" || localTesting else { throw UpdateFailure.invalidResponse }

        guard release.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateFailure.invalidResponse
        }
    }

    private static var apiBaseOverride: String? {
        guard let raw = ProcessInfo.processInfo.environment["DAXIANGSHUO_UPDATE_API_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// 正式版永远只问 `VersionAPI.latestURL`；环境变量只给冒烟测试用。
    private static var endpoint: URL {
        guard let override = apiBaseOverride,
              let base = URL(string: override.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        else { return VersionAPI.latestURL }
        return base.appending(path: "api/\(VersionAPI.product)")
    }

    // MARK: 包信息

    private static var bundleVersion: AppVersion? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(raw)
    }

    private static func bundleVersion(at application: URL) -> AppVersion? {
        let plist = application.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let raw = dictionary["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppVersion(raw)
    }

    // MARK: 压缩包

    private static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw UpdateFailure.download
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw UpdateFailure.download
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            Log.update.error("ditto 起不来：\(error.localizedDescription, privacy: .public)")
            throw UpdateFailure.extract
        }
        let detail = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: detail, encoding: .utf8) ?? ""
            Log.update.error("ditto 解包失败（status \(process.terminationStatus, privacy: .public)）：\(text, privacy: .public)")
            throw UpdateFailure.extract
        }
    }

    /// 压缩包里可能直接是「大象说.app」，也可能套了一层目录；再深就不是我们打的包。
    private static func findApplication(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            guard depth <= 3 else {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "app", url.lastPathComponent != "__MACOSX" else { continue }
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                continue
            }
            return url
        }
        return nil
    }

    /// 本进程退出后替换整包再打开。路径全部按 `$1`…`$5` 传进来，因为 .app 的路径可能带空格和中文。
    private static let helperScript = #"""
    #!/bin/sh
    # 大象说更新脚本：由运行中的 app 启动，等它退出后替换整包并重新打开。
    set -u
    pid="$1"
    target="$2"
    new="$3"
    staging="$4"
    script="$5"
    backup="${target}.old-$$"
    incoming="${target}.new-$$"

    fail() {
        echo "[daxiangshuo-update] $1" 1>&2
        rm -rf "$incoming" 2>/dev/null
        rm -rf "$staging" 2>/dev/null
        rm -f "$script" 2>/dev/null
        # 绝不能把用户晾在没有 app 的状态：盘上有什么就打开什么。
        [ -d "$target" ] && open "$target" 2>/dev/null
        exit 1
    }

    # 正常退出几十毫秒就够了，最多等 30 秒，超时就不硬来。
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -ge 300 ] && fail "timed out waiting for the app to quit"
        sleep 0.1
    done
    sleep 0.2

    rm -rf "$incoming"
    ditto "$new" "$incoming" || fail "could not copy the new app"
    xattr -dr com.apple.quarantine "$incoming" 2>/dev/null || true

    mv "$target" "$backup" || fail "could not move the old app aside"
    if ! mv "$incoming" "$target"; then
        mv "$backup" "$target"
        fail "could not install the new app"
    fi

    open "$target" || true
    rm -rf "$backup" "$staging"
    rm -f "$script"
    exit 0
    """#
}

/// 可以直接给用户看的失败原因：不含 URL、域名和路径。
private enum UpdateFailure: Error {
    case network
    case invalidResponse
    case notBundled
    case download
    case checksum
    case extract
    case versionMismatch
    case location
    case helper

    var message: String {
        switch self {
        case .network: "网络连接失败，稍后再试"
        case .invalidResponse: "更新信息读取失败，稍后再试"
        case .notBundled: "当前不是打包后的应用，无法更新"
        case .download: "更新下载失败，稍后再试"
        case .checksum: "更新包校验不通过，已放弃安装"
        case .extract: "更新包解压失败，已放弃安装"
        case .versionMismatch: "更新包版本不一致，已放弃安装"
        case .location: "当前所在的位置没有写入权限，请把大象说放进「应用程序」后再更新"
        case .helper: "更新程序启动失败，请手动下载新版本"
        }
    }

    /// 日志用的稳定短名，不做本地化。
    var key: String {
        switch self {
        case .network: "network"
        case .invalidResponse: "invalid_response"
        case .notBundled: "not_bundled"
        case .download: "download"
        case .checksum: "checksum"
        case .extract: "extract"
        case .versionMismatch: "version_mismatch"
        case .location: "location"
        case .helper: "helper"
        }
    }
}
