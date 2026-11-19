import SwiftUI

struct MainView: View {
    @Bindable var router: Router
    let settings: AppSettings
    let history: HistoryStore
    let phrases: PhraseStore
    let dictation: DictationController
    let updates: UpdateService

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router, updates: updates)
            Rectangle().fill(Theme.sidebarBorder).frame(width: 1)
            Group {
                switch router.section ?? .general {
                case .general:
                    GeneralSettingsView(settings: settings, dictation: dictation, updates: updates)
                case .models:
                    ModelSettingsView(settings: settings, dictation: dictation)
                case .statistics:
                    StatisticsView(history: history, usage: UsageStore.shared)
                case .phrases:
                    PhrasesView(phrases: phrases)
                case .history:
                    HistoryView(history: history)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .frame(width: Theme.windowSize.width, height: Theme.windowSize.height)
    }
}

// MARK: 侧栏

private struct Sidebar: View {
    @Bindable var router: Router
    let updates: UpdateService
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// 黑白版 logo（模板图像，颜色跟随文字）。
    private let logo = IconRenderer.statusImage(wavePhase: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 给左上角的红绿灯按钮留位置。
            Color.clear.frame(height: 44)
            item(.general)
            item(.models)
            item(.phrases)
            item(.statistics)
            item(.history)
            Spacer()
            HStack(spacing: 6) {
                WebsiteLink(logo: logo)
                Spacer()
                // 有更新时这一格换成蓝色的「升级」按钮；没有就照常显示 GitHub 和版本号。
                if pendingUpdate {
                    UpdateButton(updates: updates)
                } else {
                    GitHubLink()
                    if let version { Text("v\(version)") }
                }
            }
            .font(Theme.font)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    /// 有新版本要装（或正在下载/安装）：左下角那格让位给「升级」按钮。
    private var pendingUpdate: Bool {
        switch updates.state {
        case .ready, .downloading, .installing: true
        default: false
        }
    }

    private func item(_ section: MainSection) -> some View {
        SidebarRow(section: section, selected: (router.section ?? .general) == section) {
            router.section = section
        }
    }
}

/// 左下角的 logo 和「大象说」，点击打开官网；灰色，鼠标移上去略深。
private struct WebsiteLink: View {
    let logo: NSImage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: logo)
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
            Text("大象说")
        }
        .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(AppLinks.website) }
        .help("官网 eput.ruoxie.com")
    }
}

/// 项目主页的 GitHub 图标链接，灰色，鼠标移上去略深。
private struct GitHubLink: View {
    @State private var hovering = false

    var body: some View {
        if let image = IconRenderer.githubImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { NSWorkspace.shared.open(AppLinks.github) }
                .help("GitHub 项目主页")
        }
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .frame(width: 16)
                Text(section.title)
                    .font(Theme.font)
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .circular)
                .fill(selected ? Theme.sidebarSelection : (hovering ? Theme.sidebarHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: 统计信息

struct StatisticsView: View {
    let history: HistoryStore
    let usage: UsageStore

    var body: some View {
        Page(scrolls: true) {
            SectionTitle("统计")
            Card {
                HStack(spacing: 0) {
                    stat("今日字数", "\(history.todayChars)")
                    Rectangle().fill(Theme.divider).frame(width: 1, height: 36)
                    stat("历史条数", "\(history.totalCount)")
                }
                .padding(.vertical, 12)
            }

            SectionTitle("API 用量", info: "语音识别按发送给识别服务的音频时长计费，这里统计的就是这个时长。数据来自本机，和火山引擎控制台的账单可能有细微出入，以控制台为准。\n\n首次升级到带用量统计的版本时，之前的用量按历史记录里每条的时长估算。")
            Card {
                HStack(spacing: 0) {
                    stat("近 30 天", Self.duration(usage.last30Seconds))
                    Rectangle().fill(Theme.divider).frame(width: 1, height: 36)
                    stat("本次打开以来", Self.duration(usage.sinceLaunchSeconds))
                    Rectangle().fill(Theme.divider).frame(width: 1, height: 36)
                    stat("累计", Self.duration(usage.totalSeconds))
                }
                .padding(.vertical, 12)
                CardDivider()
                chart
                CardDivider()
                quota
            }
        }
        .onAppear { usage.reload() }
    }

    // MARK: 近 7 天

    private var chart: some View {
        let days = usage.last7Days
        let peak = max(days.map(\.seconds).max() ?? 0, 60)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 4) {
                    Text(day.seconds > 0 ? Self.short(day.seconds) : "")
                        .foregroundStyle(Theme.secondary)
                        .frame(height: 16)
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(index == days.count - 1 ? Theme.accent : Theme.tertiary)
                            .frame(width: 22, height: day.seconds > 0 ? max(3, 44 * day.seconds / peak) : 2)
                            .opacity(day.seconds > 0 ? 1 : 0.5)
                    }
                    .frame(height: 44)
                    Text(index == days.count - 1 ? "今天" : Self.label(day.date))
                        .foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 免费额度

    private var quota: some View {
        let used = usage.totalSeconds
        let total = UsageStore.freeQuotaSeconds
        let ratio = min(used / total, 1)
        let color = used >= total ? Theme.danger : (ratio > 0.8 ? Theme.warning : Theme.accent)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("免费额度 20 小时")
                Spacer()
                Text(used >= total ? "已用完" : "剩余 \(Self.duration(total - used))")
                    .foregroundStyle(used >= total ? Theme.danger : Theme.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.divider)
                    Capsule().fill(color).frame(width: max(ratio > 0 ? 4 : 0, proxy.size.width * ratio))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: 格式

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .regular).monospacedDigit())
                .foregroundStyle(Theme.text)
            Text(title).font(Theme.font).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    /// 例如「0 秒」「45 秒」「12 分 30 秒」「1 小时 23 分」。
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
    }

    /// 柱子上方的简短数值。
    static func short(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) 分" }
        return String(format: "%.1f 时", seconds / 3600)
    }

    private static func label(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
}
