import AppKit

/// 所有图标都用代码绘制，不需要额外的图片资源。设计坐标系为 100x100，y 轴向上。
enum IconRenderer {
    /// 正面大象头：两只大耳朵、圆脑袋、向右卷的象鼻，眼睛镂空。
    static func drawElephant(in rect: CGRect, color: NSColor, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 100, y: rect.height / 100)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)

        ctx.fillEllipse(in: CGRect(x: 1, y: 38, width: 42, height: 52))
        ctx.fillEllipse(in: CGRect(x: 57, y: 38, width: 42, height: 52))

        let head = CGRect(x: 25, y: 30, width: 50, height: 58)
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: head)
        ctx.setBlendMode(.normal)
        ctx.fillEllipse(in: head)

        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: 50, y: 42))
        trunk.addCurve(to: CGPoint(x: 47, y: 14),
                       control1: CGPoint(x: 50, y: 30), control2: CGPoint(x: 45, y: 22))
        trunk.addCurve(to: CGPoint(x: 63, y: 13),
                       control1: CGPoint(x: 49, y: 3), control2: CGPoint(x: 61, y: 3))
        ctx.addPath(trunk)
        ctx.setLineWidth(12)
        ctx.setLineCap(.round)
        ctx.strokePath()

        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 36, y: 60, width: 8, height: 8))
        ctx.fillEllipse(in: CGRect(x: 56, y: 60, width: 8, height: 8))
        ctx.setBlendMode(.normal)

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: 状态栏

    private static let waveFrames: [[CGFloat]] = [
        [5, 10, 6], [8, 6, 11], [11, 8, 5], [6, 12, 8],
    ]

    /// wavePhase 为 nil 时是空闲图标（18pt 宽）；录音时右侧加三根声波竖条（29pt 宽）。
    static func statusImage(wavePhase: Int?) -> NSImage {
        let width: CGFloat = wavePhase == nil ? 18 : 29
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawElephant(in: CGRect(x: 0, y: 0, width: 18, height: 18), color: .black, context: ctx)
            if let phase = wavePhase {
                ctx.setFillColor(NSColor.black.cgColor)
                let heights = waveFrames[phase % waveFrames.count]
                for (i, h) in heights.enumerated() {
                    let x = 20 + CGFloat(i) * 3
                    let bar = CGRect(x: x, y: 9 - h / 2, width: 2, height: h)
                    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil))
                }
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// GitHub 官方标志（Octicons mark-github），作为模板图像使用，颜色由界面决定。
    static let githubImage: NSImage? = {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>"##
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    /// 胶囊里用的白色小象。
    static func capsuleImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawElephant(in: rect, color: .white, context: ctx)
            return true
        }
    }

    // MARK: App 图标

    static func drawAppIcon(side: CGFloat, context ctx: CGContext) {
        let inset = side * 0.1
        let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = body.width * 0.225
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.025,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [
            NSColor(srgbRed: 0.33, green: 0.80, blue: 0.86, alpha: 1).cgColor,
            NSColor(srgbRed: 0.20, green: 0.42, blue: 0.93, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                                   end: CGPoint(x: body.maxX, y: body.minY), options: [])
        }

        let elephantSide = body.width * 0.66
        let elephantRect = CGRect(x: body.midX - elephantSide / 2 - body.width * 0.05,
                                  y: body.midY - elephantSide / 2 + body.width * 0.02,
                                  width: elephantSide, height: elephantSide)
        drawElephant(in: elephantRect, color: .white, context: ctx)

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        let barW = body.width * 0.045
        let baseX = elephantRect.minX + elephantSide * 0.8
        let baseY = elephantRect.minY + elephantSide * 0.12
        for (i, h) in [0.10, 0.18, 0.12].enumerated() {
            let height = body.width * CGFloat(h)
            let rect = CGRect(x: baseX + CGFloat(i) * barW * 1.9,
                              y: baseY - height / 2 + body.width * 0.02,
                              width: barW, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func appIconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawAppIcon(side: rect.width, context: ctx)
            return true
        }
    }

    static func exportIconset(to directory: String) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
                    let gc = NSGraphicsContext(bitmapImageRep: rep) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                drawAppIcon(side: CGFloat(px), context: gc.cgContext)
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name))
            }
        }
    }
}
