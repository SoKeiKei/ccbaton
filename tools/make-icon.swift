// 生成 CCBaton 的应用图标：深靛蓝圆角方块 + 双环（外圈 5 小时、内圈 7 天）+ 中间的左右互换箭头。
// 用法：swift tools/make-icon.swift 输出目录     → 在输出目录里生成 AppIcon.iconset 和 icon-1024.png
//      然后：iconutil -c icns 输出目录/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.interpolationQuality = .high
    let s = CGFloat(size) / 1024            // 以 1024 画布设计，按比例缩放
    cg.scaleBy(x: s, y: s)

    // macOS 图标网格：824 的圆角方块，四周各留 100 给阴影
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // 投影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.38).cgColor)
    cg.addPath(path); cg.setFillColor(NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.26, alpha: 1).cgColor); cg.fillPath()
    cg.restoreGState()

    // 底色渐变
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let colors = [NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.60, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.30, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.19, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // 顶部一道柔和高光
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [.drawsBeforeStartLocation])
    cg.restoreGState()
    // 细描边
    cg.addPath(path); cg.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor); cg.setLineWidth(3); cg.strokePath()

    // 双环
    let c = CGPoint(x: 512, y: 512)
    func ring(_ r: CGFloat, _ w: CGFloat, _ fraction: CGFloat, _ color: NSColor) {
        cg.setLineWidth(w); cg.setLineCap(.round)
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        cg.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); cg.strokePath()
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 22, color: color.withAlphaComponent(0.55).cgColor)
        cg.setStrokeColor(color.cgColor)
        cg.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - fraction * .pi * 2, clockwise: true); cg.strokePath()
        cg.restoreGState()
    }
    ring(262, 70, 0.74, NSColor(calibratedRed: 0.30, green: 0.66, blue: 1.00, alpha: 1))   // 外圈：5 小时，蓝
    ring(158, 70, 0.46, NSColor(calibratedRed: 0.36, green: 0.92, blue: 0.66, alpha: 1))   // 内圈：7 天，薄荷绿

    // 中间的左右互换箭头
    cg.setStrokeColor(NSColor.white.cgColor); cg.setLineWidth(26); cg.setLineCap(.round); cg.setLineJoin(.round)
    func arrow(y: CGFloat, toRight: Bool) {
        let a: CGFloat = toRight ? -52 : 52, b: CGFloat = toRight ? 52 : -52
        let d: CGFloat = toRight ? -26 : 26
        cg.move(to: CGPoint(x: c.x + a, y: y)); cg.addLine(to: CGPoint(x: c.x + b, y: y))
        cg.move(to: CGPoint(x: c.x + b + d, y: y + 26)); cg.addLine(to: CGPoint(x: c.x + b, y: y)); cg.addLine(to: CGPoint(x: c.x + b + d, y: y - 26))
        cg.strokePath()
    }
    arrow(y: c.y + 30, toRight: true)
    arrow(y: c.y - 30, toRight: false)

    NSGraphicsContext.current = nil
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-out"
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
let specs: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in specs { write(draw(size: px), "\(set)/icon_\(name).png") }
write(draw(size: 1024), out + "/icon-1024.png")
print("已生成 \(set)")
