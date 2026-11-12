// 用小豆的真实 3D 模型渲染头像，合成成 App 图标。
// 编译：swiftc -swift-version 6 -default-isolation MainActor -O App/Mascot.swift design/logo/mascot_icon.swift -o /tmp/mascot_icon
// 用法：mascot_icon App/MascotAssets design/logo/icon_1024.png 0.60 2.7
import AppKit
import SceneKit

@main struct Main {
    static func main() {
        let args = CommandLine.arguments
        MascotScene.assetFolder = URL(fileURLWithPath: args[1])
        let mascot = MascotScene()
        mascot.apply(.idle, .mid, animated: false)
        mascot.scene.background.contents = NSColor.clear
        // 耳机上的灯用品牌的琥珀色，常亮
        mascot.setRing(NSColor(calibratedRed: 1.0, green: 0.50, blue: 0.06, alpha: 1), glow: (0.7, 0.7, 4), animated: false)

        // 自己的镜头：对着头和脖子上的耳机，稍微俯一点
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 22
        let cy = Double(args.count > 3 ? args[3] : "0.60") ?? 0.60, dist = Double(args.count > 4 ? args[4] : "2.35") ?? 2.35
        camera.position = SCNVector3(0, cy + 0.06, dist)
        camera.eulerAngles = SCNVector3(-0.03, 0, 0)
        mascot.scene.rootNode.addChildNode(camera)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = mascot.scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let shot = renderer.snapshot(atTime: 0, with: CGSize(width: 1648, height: 1648), antialiasingMode: .multisampling4X)
        guard let bust = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let size: CGFloat = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
        let space = CGColorSpaceCreateDeviceRGB()

        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let plate = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
        ctx.addPath(plate); ctx.setFillColor(rgb(0.08, 0.08, 0.085)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(plate); ctx.clip()
        ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.19, 0.18, 0.17), rgb(0.06, 0.06, 0.065)] as CFArray, locations: [0, 1])!,
                               start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
        // 小豆背后一团琥珀色的光，像舞台上的一盏灯
        ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 0.72, 0.26, 0.80), rgb(1, 0.62, 0.16, 0.28), rgb(1, 0.6, 0.1, 0)] as CFArray, locations: [0, 0.5, 1])!,
                               startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 520, options: [])
        // 小豆：半身，底下被底板的边裁掉
        ctx.interpolationQuality = .high
        ctx.draw(bust, in: CGRect(x: 100, y: 100, width: 824, height: 824))
        // 底部压一点暗，让它像是从底板里探出来
        ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.04, 0.04, 0.045, 0.55), rgb(0.04, 0.04, 0.045, 0)] as CFArray, locations: [0, 1])!,
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 300), options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.24), rgb(1, 1, 1, 0.02)] as CFArray, locations: [0, 1])!,
                               start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 500), options: [])
        ctx.restoreGState()

        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
        print("ok")
    }
}
