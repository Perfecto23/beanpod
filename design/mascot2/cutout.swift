// 用系统的主体识别把小豆从纯色背景里抠出来，存成透明底 PNG，并裁掉四周多余的空白。
// 用法：swift cutout.swift 输入.png 输出.png
import AppKit
import Vision
import CoreImage

let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("读不到图") }
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: image)
try handler.perform([request])
guard let result = request.results?.first else { fatalError("没认出主体") }
let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
let ci = CIImage(cvPixelBuffer: buffer)
let context = CIContext()
guard let cut = context.createCGImage(ci, from: ci.extent) else { fatalError("出不了图") }
// 放进一张正方形画布，四周留一点边，各个状态大小一致
let side = max(cut.width, cut.height)
let canvas = Int(Double(side) * 1.06)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
g.interpolationQuality = .high
g.draw(cut, in: CGRect(x: (canvas - cut.width) / 2, y: (canvas - side) / 2, width: cut.width, height: cut.height))
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
