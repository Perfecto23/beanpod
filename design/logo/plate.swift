// 把一张满幅的方图裁成 macOS 图标：圆角方块、四周留边、底下一点投影、上沿一道细亮边。
// 用法：swift design/logo/plate.swift 输入.png 输出.png
import AppKit

let args = CommandLine.arguments
guard let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("读不到图") }
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let plate = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(plate); ctx.setFillColor(rgb(0.08, 0.08, 0.085)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(plate); ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(source, in: body)
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.02)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 500), options: [])
ctx.restoreGState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
