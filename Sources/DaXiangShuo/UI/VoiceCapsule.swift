import AppKit
import QuartzCore

/// 屏幕下方的语音状态胶囊。启动时就建好，显示和隐藏都是瞬时的，不抢焦点、不接收鼠标。
final class VoiceCapsule: NSObject {
    var levelProvider: (() -> Float)?
    /// 麦克风是否已经开始收音；冷启动的几百毫秒里波形显示为暗色的「准备中」。
    var liveProvider: (() -> Bool)?

    private static let height: CGFloat = 40
    private static let barCount = 7
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let barMin: CGFloat = 3
    private static let barMax: CGFloat = 22
    private static let barsX: CGFloat = 44
    private static let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    private static let compactWidth = barsX + barsWidth + 17
    private static let previewWidth: CGFloat = 460
    /// 预览/定稿时文字从波形右边开始。
    private static let previewLabelX = barsX + barsWidth + 12
    /// 提示文字两侧留白：右边 12pt，另外 label 还会多出 10pt 余量抵消 NSTextField 的内边距。
    private static let textPadding: CGFloat = 22
    private static let labelSlack: CGFloat = 10
    private static let weights: [CGFloat] = [0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55]

    private let panel: NSPanel
    private let container = NSView()
    private let tint = CALayer()
    private let barsLayer = CALayer()
    private var bars: [CALayer] = []
    private let icon = NSImageView()
    /// 提示模式下的 SF Symbol（麦克风被划掉、警告三角等），用品牌图标的位置显示。
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// 定稿中的加载指示：左右各三个轮流亮的小圆点（画在胶囊内部，不会溢出去）。
    private var dots: [CALayer] = []
    private var dotsRight: [CALayer] = []
    /// 定稿时最右边的「定稿中」。
    private let tagLabel = NSTextField(labelWithString: "")
    private let speeds: [Double] = (0..<VoiceCapsule.barCount).map { _ in Double.random(in: 7...13) }
    private let phases: [Double] = (0..<VoiceCapsule.barCount).map { _ in Double.random(in: 0...(2 * .pi)) }
    private var link: CADisplayLink?
    private var smoothed: Float = 0
    private var previewMode = false
    /// 当前这块胶囊是「提示/状态」而不是录音波形；只有这种状态才需要被 clearNotice() 收掉。
    private var showingNotice = false
    /// 松键之后、文字还在等定稿：波形换成一段匀速跑动的波，表明后台还在干活。
    private var finalizing = false
    /// 提示条左侧给图标留的宽度，换文字时按同一个值重算总宽度。
    private var noticeReserved: CGFloat = 0
    private var dismissWork: DispatchWorkItem?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.compactWidth, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        // 纯黑背景（不再使用半透明的毛玻璃），细描边让它在深色壁纸上也分得出轮廓。
        let effect = NSView(frame: panel.contentLayoutRect)
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.black.cgColor
        effect.layer?.cornerRadius = Self.height / 2
        effect.layer?.masksToBounds = true
        // 一条设备像素；0.5 在 1x 屏上只有半个像素，描边会发灰。
        effect.layer?.borderWidth = Theme.hairline
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        container.frame = effect.bounds
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        effect.addSubview(container)

        tint.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        tint.isHidden = true
        container.layer?.addSublayer(tint)

        barsLayer.frame = CGRect(x: Self.barsX, y: 0, width: Self.barsWidth, height: Self.height)
        for i in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.frame = CGRect(x: CGFloat(i) * (Self.barWidth + Self.barGap), y: (Self.height - Self.barMin) / 2,
                               width: Self.barWidth, height: Self.barMin)
            barsLayer.addSublayer(bar)
            bars.append(bar)
        }
        container.layer?.addSublayer(barsLayer)

        icon.image = IconRenderer.capsuleImage(size: 20)
        icon.frame = NSRect(x: 15, y: (Self.height - 20) / 2, width: 20, height: 20)
        container.addSubview(icon)

        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.frame = NSRect(x: 15, y: (Self.height - 18) / 2, width: 18, height: 18)
        symbol.isHidden = true
        container.addSubview(symbol)

        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.isHidden = true
        container.addSubview(label)

        for set in 0..<2 {
            var layers: [CALayer] = []
            for _ in 0..<3 {
                let dot = CALayer()
                dot.backgroundColor = NSColor.systemTeal.cgColor
                dot.cornerRadius = 2.75
                dot.frame = CGRect(x: 14, y: (Self.height - 5.5) / 2, width: 5.5, height: 5.5)
                dot.opacity = 0.25
                dot.isHidden = true
                container.layer?.addSublayer(dot)
                layers.append(dot)
            }
            if set == 0 { dots = layers } else { dotsRight = layers }
        }

        tagLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tagLabel.textColor = .systemTeal
        tagLabel.isHidden = true
        container.addSubview(tagLabel)
    }

    /// 按下快捷键时调用。preview 为 true 时右边会显示实时文字，宽度随文字长出来。
    func show(preview: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        stopLink()
        showingNotice = false
        tint.isHidden = true
        barsLayer.isHidden = false
        symbol.isHidden = true
        icon.isHidden = false
        stopDots()
        label.textColor = .white
        previewMode = preview
        finalizing = false
        label.stringValue = ""
        label.isHidden = !preview
        smoothed = 0
        resetBars()
        // 一开始就用最窄的宽度：随着文字进来再长，别一按下就占一大条。
        layout(width: Self.compactWidth, labelX: Self.previewLabelX)
        panel.orderFrontRegardless()
        startLink()
    }

    /// 排障用：当前面板在屏幕上的位置。
    var debugFrame: NSRect { panel.frame }

    /// 松开快捷键时调用。
    func hide() {
        guard dismissWork == nil else { return }
        finalizing = false
        stopLink()
        panel.orderOut(nil)
    }

    func setPreview(_ text: String) {
        guard previewMode, panel.isVisible, dismissWork == nil, !finalizing else { return }
        showPreviewText(Self.plain(text), text: text)
    }

    /// 预览宽度跟着文字长，到 previewWidth 就不再长（文字从头上裁掉，保留最新说的）。
    private func showPreviewText(_ attributed: NSAttributedString, text: String) {
        let maxLabel = Self.previewWidth - Self.previewLabelX - Self.textPadding
        let textWidth = ceil(attributed.size().width)
        label.attributedStringValue = textWidth > maxLabel
            ? Self.plain(tailFitted(text, width: maxLabel))
            : attributed
        let used = min(textWidth, maxLabel)
        let width = min(max(Self.compactWidth, Self.previewLabelX + used + Self.textPadding),
                        Self.previewWidth)
        guard abs(panel.frame.width - width) > 1 else { return }
        layout(width: width, labelX: Self.previewLabelX)
    }

    /// 只保留能塞进 width 的尾部，前面用省略号：长句时一直能看到最新说的那几个字。
    private func tailFitted(_ text: String, width: CGFloat) -> String {
        let font = label.font ?? NSFont.systemFont(ofSize: 13)
        let characters = Array(text)
        func fits(_ count: Int) -> Bool {
            let candidate = "…" + String(characters.suffix(count))
            return ceil((candidate as NSString).size(withAttributes: [.font: font]).width) <= width
        }
        guard !fits(characters.count) else { return text }
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return "…" + String(characters.suffix(low))
    }

    func showError(_ message: String) {
        present(message, symbol: "exclamationmark.triangle.fill", color: .systemRed,
                fill: NSColor.systemRed.withAlphaComponent(0.85), seconds: 2.8)
    }

    /// 整段识别（DeepSeek）上传期间、整段改写在飞时的状态条，结果回来时用 clearNotice() 收掉。
    func showBusy(_ message: String) {
        present(message, symbol: "waveform", color: .systemOrange, fill: nil, seconds: 20)
    }

    /// 状态条已经亮着时换一句文字：「正在转写…」→「整理中…」，不闪一下、也不重新计时。
    func setBusyText(_ message: String) {
        guard showingNotice, panel.isVisible, dismissWork != nil else {
            showBusy(message)
            return
        }
        let plain = Self.plain(message)
        label.attributedStringValue = plain
        let maxText = 560 - noticeReserved - Self.textPadding
        let textWidth = min(ceil(plain.size().width), maxText)
        layout(width: min(noticeReserved + textWidth + Self.textPadding, 560), labelX: noticeReserved)
    }

    /// 立刻收起当前提示（不等它自己到时间消失）。
    /// 正在显示录音波形时什么也不做：那时候收的是别的会话的提示，不能把新一轮的胶囊弄没。
    func clearNotice() {
        guard showingNotice else { return }
        showingNotice = false
        finalizing = false
        stopDots()
        stopLink()
        dismissWork?.cancel()
        dismissWork = nil
        tint.isHidden = true
        symbol.isHidden = true
        icon.isHidden = false
        label.textColor = .white
        panel.orderOut(nil)
    }

    /// 温和的提示：不整块变红，只在左侧放一个琥珀色的图标，几秒后自己消失。
    /// 用于「没有检测到麦克风」这类需要知道、但不用打断操作的状态。
    func showNotice(_ message: String, symbol name: String = "mic.slash.fill", seconds: Double = 4.5) {
        present(message, symbol: name, color: .systemOrange, fill: nil, seconds: seconds)
    }

    /// 松键之后、文字还在等定稿：**保留刚说的那段文字**，左边的波形换成一段匀速跑动的波，
    /// 让人看得出后台还在干活，不会觉得卡住了。
    func showFinalizing(_ text: String) {
        dismissWork?.cancel()
        dismissWork = nil
        showingNotice = true
        finalizing = true
        previewMode = true
        tint.isHidden = true
        // 和「正在说话」明显区分：波形换成三个轮流亮的小圆点，正文压暗。
        icon.isHidden = true
        barsLayer.isHidden = true
        symbol.isHidden = true
        label.isHidden = false
        startDots()
        noticeReserved = Self.previewLabelX
        smoothed = 0
        layoutFinalizing(text)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startLink()
        // 兜底：定稿一直不回来也别把这条挂在屏幕上。
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissWork = nil
            self.finalizing = false
            self.showingNotice = false
            self.stopLink()
            self.panel.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// 定稿的样子：`● ● ●   正文   ● ● ● 定稿中`，左右两侧对称，标签贴最右边。
    private func layoutFinalizing(_ text: String) {
        let inset: CGFloat = 14          // 胶囊两端留白
        let dotSize: CGFloat = 5.5
        let dotGap: CGFloat = 6
        let dotsWidth = dotSize * 3 + dotGap * 2
        let gapAfterDots: CGFloat = 10   // 圆点离正文近一点
        let gapBeforeRight: CGFloat = 10   // 和左边一样的间距，看起来才是对称的
        let gapBeforeTag: CGFloat = 8

        let tag = NSAttributedString(string: "定稿中", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.systemTeal,
        ])
        // NSTextField 自身有几 pt 内边距，不留余量会把「定稿中」裁成「定稿」。
        let tagWidth = ceil(tag.size().width) + 8
        let rightWidth = dotsWidth + gapBeforeTag + tagWidth
        let maxBody = Self.previewWidth - inset * 2 - dotsWidth * 2
            - gapAfterDots - gapBeforeRight - gapBeforeTag - tagWidth
        let shown = ceil(Self.plain(text).size().width) > maxBody
            ? tailFitted(text, width: maxBody)
            : text
        let body = Self.dimmed(shown)
        let bodyWidth = ceil(body.size().width)
        let width = inset + dotsWidth + gapAfterDots + bodyWidth + gapBeforeRight + rightWidth + inset

        layout(width: width, labelX: inset + dotsWidth + gapAfterDots)
        var bodyFrame = label.frame
        bodyFrame.size.width = bodyWidth
        label.frame = bodyFrame

        // 左右两组圆点
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(x: inset + CGFloat(i) * (dotSize + dotGap),
                               y: (Self.height - dotSize) / 2, width: dotSize, height: dotSize)
        }
        let rightDotsX = width - inset - rightWidth
        for (i, dot) in dotsRight.enumerated() {
            dot.frame = CGRect(x: rightDotsX + CGFloat(i) * (dotSize + dotGap),
                               y: (Self.height - dotSize) / 2, width: dotSize, height: dotSize)
        }
        tagLabel.attributedStringValue = tag
        tagLabel.frame = NSRect(x: rightDotsX + dotsWidth + gapBeforeTag,
                                y: (Self.height - 16) / 2, width: tagWidth, height: 16)
        tagLabel.isHidden = false
    }

    private func present(_ message: String, symbol name: String, color: NSColor,
                         fill: NSColor?, seconds: Double) {
        present(Self.plain(message), symbol: name, color: color, fill: fill, seconds: seconds)
    }

    private static func plain(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white,
        ])
    }

    private func present(_ text: NSAttributedString, symbol name: String, color: NSColor,
                         fill: NSColor?, seconds: Double) {
        stopLink()
        stopDots()
        dismissWork?.cancel()
        dismissWork = nil
        barsLayer.isHidden = true
        label.isHidden = false
        label.attributedStringValue = text

        let reserved = fill == nil ? Self.barsX : 15 + 20 + 12
        noticeReserved = reserved
        if let fill {
            tint.backgroundColor = fill.cgColor
            tint.isHidden = false
            icon.isHidden = false
            symbol.isHidden = true
        } else {
            tint.isHidden = true
            icon.isHidden = true
            symbol.isHidden = false
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbol.contentTintColor = color
        }
        // 用字符串本身的宽度来算胶囊宽度：label 的 intrinsicContentSize 受当前 frame 影响，
        // 上一轮被截断过的话会一直算窄。再留 10pt 余量，抵消 NSTextField 自身的内边距，
        // 否则末尾会退化成省略号。
        let maxText = 560 - reserved - Self.textPadding
        let textWidth = min(ceil(text.size().width), maxText)
        layout(width: min(reserved + textWidth + Self.textPadding, 560), labelX: reserved)
        showingNotice = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissWork = nil
            self.showingNotice = false
            self.tint.isHidden = true
            self.symbol.isHidden = true
            self.icon.isHidden = false
            self.label.textColor = .white
            self.panel.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: 私有

    private func layout(width: CGFloat, labelX: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: round(visible.midX - width / 2), y: visible.minY + 56,
                           width: width, height: Self.height)
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
        CATransaction.commit()
        label.frame = NSRect(x: labelX, y: (Self.height - 18) / 2,
                             width: max(0, width - labelX - (Self.textPadding - Self.labelSlack)), height: 18)
    }

    /// 定稿中的加载指示：三个小圆点依次亮起来，像在「敲」。
    private func startDots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (offset, group) in [dots, dotsRight].enumerated() {
            for (index, dot) in group.enumerated() {
                dot.isHidden = false
                dot.opacity = 0.45
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.45, 1, 0.45]
                fade.keyTimes = [0, 0.5, 1]
                fade.duration = 1.05
                fade.repeatCount = .infinity
                fade.beginTime = CACurrentMediaTime() + Double(offset + index) * 0.17
                dot.add(fade, forKey: "fade")
            }
        }
        CATransaction.commit()
    }

    private func stopDots() {
        for dot in dots + dotsRight {
            dot.removeAnimation(forKey: "fade")
            dot.isHidden = true
            dot.opacity = 0.45
        }
        tagLabel.isHidden = true
    }

    /// 定稿中的正文：压暗一档，表示「还没最终确定」。
    private static func dimmed(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ])
    }

    private func startLink() {
        guard link == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            var frame = bar.frame
            frame.size.height = Self.barMin
            frame.origin.y = (Self.height - Self.barMin) / 2
            bar.frame = frame
        }
        CATransaction.commit()
    }

    /// 波形只求「看得出在收音」：音量决定整体幅度，每根竖条各自按不同频率摆动。
    @objc private func tick(_ link: CADisplayLink) {
        if finalizing {
            // 定稿中：不看麦克风电平，跑一段匀速的波，像「在处理」。
            let t = CACurrentMediaTime()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barsLayer.opacity = 1
            for (i, bar) in bars.enumerated() {
                let phase = t * 3.4 - Double(i) * 0.5
                let level = 0.22 + 0.78 * max(0, sin(phase))
                let h = Self.barMin + (Self.barMax - Self.barMin) * CGFloat(level) * Self.weights[i]
                var frame = bar.frame
                frame.size.height = h
                frame.origin.y = (Self.height - h) / 2
                bar.frame = frame
            }
            CATransaction.commit()
            return
        }
        let live = liveProvider?() ?? true
        let target: Float
        if live {
            let rms = levelProvider?() ?? 0
            let db = 20 * log10(max(rms, 1e-5))
            target = min(max((db + 52) / 36, 0), 1)
        } else {
            target = 0.18
        }
        let rate: Float = target > smoothed ? 0.55 : 0.18
        smoothed += (target - smoothed) * rate

        let t = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.opacity = live ? 1 : 0.35
        for (i, bar) in bars.enumerated() {
            let wobble = 0.55 + 0.45 * sin(t * speeds[i] + phases[i])
            let h = Self.barMin + (Self.barMax - Self.barMin) * CGFloat(smoothed) * CGFloat(wobble) * Self.weights[i]
            var frame = bar.frame
            frame.size.height = h
            frame.origin.y = (Self.height - h) / 2
            bar.frame = frame
        }
        CATransaction.commit()
    }
}
