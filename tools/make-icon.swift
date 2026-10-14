// 生成 App 图标：Resources/AppIcon.icns
// 运行：swift tools/make-icon.swift（在仓库根目录）
// 图案：紫蓝渐变圆角方块 + 白色手柄 + 两侧声波弧线 + 灯条色光
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格：内容区 824/1024，圆角约 185
    let inset = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); bg.fill()
    ctx.restoreGState()
    bg.addClip()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.20, blue: 0.95, alpha: 1),
                        NSColor(red: 0.10, green: 0.45, blue: 1.00, alpha: 1)])!.draw(in: rect, angle: -60)

    // 灯条色光（底部）
    let glow = NSGradient(colors: [NSColor(red: 1, green: 0.25, blue: 0.6, alpha: 0.85),
                                   NSColor(red: 0.2, green: 0.95, blue: 0.9, alpha: 0)])!
    glow.draw(fromCenter: CGPoint(x: size * 0.5, y: rect.minY), radius: 0,
              toCenter: CGPoint(x: size * 0.5, y: rect.minY), radius: 420 * s, options: [])

    // 两侧声波弧线
    NSColor.white.withAlphaComponent(0.9).setStroke()
    for (i, r) in [CGFloat(285), 340, 395].enumerated() {
        for side in [CGFloat(-1), 1] {
            let p = NSBezierPath()
            let c = CGPoint(x: size / 2, y: size * 0.53)
            let start: CGFloat = side < 0 ? 155 : -25, end: CGFloat = side < 0 ? 205 : 25
            p.appendArc(withCenter: c, radius: r * s, startAngle: start, endAngle: end)
            p.lineWidth = (30 - CGFloat(i) * 6) * s
            p.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.95 - CGFloat(i) * 0.25).setStroke()
            p.stroke()
        }
    }

    // 手柄（SF Symbol）
    let config = NSImage.SymbolConfiguration(pointSize: 270 * s, weight: .semibold)
    if let pad = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: pad.size, flipped: false) { r in
            pad.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: CGRect(x: (size - w) / 2, y: size * 0.53 - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "iconutil failed")
