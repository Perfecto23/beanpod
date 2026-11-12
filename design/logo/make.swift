// 画豆仓的图标：石墨底上一颗暖白的「豆」，豆身上一道琥珀色的声波。
// 用法：swift design/logo/make.swift design/logo/icon_1024.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let space = CGColorSpaceCreateDeviceRGB()

// 底板：macOS 图标的圆角方块，四周留边
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let plate = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(plate); ctx.setFillColor(rgb(0.08, 0.08, 0.085)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(plate); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.165, 0.16), rgb(0.055, 0.055, 0.06)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// 左上角一团琥珀色的光
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 0.70, 0.24, 0.20), rgb(1, 0.70, 0.24, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: 300, y: 820), startRadius: 0, endCenter: CGPoint(x: 300, y: 820), endRadius: 620, options: [])
ctx.restoreGState()
// 底板上沿一道细亮边
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.02)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 500), options: [])
ctx.restoreGState()

// 豆：一颗斜放的胶囊
ctx.saveGState()
ctx.translateBy(x: 512, y: 512); ctx.rotate(by: .pi / 9)
let bean = CGRect(x: -270, y: -168, width: 540, height: 336)
let beanPath = CGPath(roundedRect: bean, cornerWidth: 168, cornerHeight: 168, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.55))
ctx.addPath(beanPath); ctx.setFillColor(rgb(0.96, 0.93, 0.87)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(beanPath); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 0.99, 0.96), rgb(0.90, 0.86, 0.79)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: 168), end: CGPoint(x: 0, y: -168), options: [])
ctx.restoreGState()
ctx.restoreGState()
// 声波：五根琥珀色的竖条，中间最高。豆是斜的，声波是正的
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
let heights: [CGFloat] = [64, 132, 196, 132, 64]
let barWidth: CGFloat = 38, gap: CGFloat = 32
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let x = -total / 2 + CGFloat(i) * (barWidth + gap)
    let bar = CGPath(roundedRect: CGRect(x: x, y: -h / 2, width: barWidth, height: h), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(bar); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(1.0, 0.72, 0.24), rgb(0.90, 0.52, 0.08)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: h / 2), end: CGPoint(x: 0, y: -h / 2), options: [])
    ctx.restoreGState()
}
ctx.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
