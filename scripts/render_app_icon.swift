// Original BetterFit concentric-arc mark. Run with macOS Swift to regenerate the 1024px asset.
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
context.setFillColor(color(0x0D1113))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
let atmosphere = CGGradient(colorsSpace: space,
                            colors: [color(0x29332C), color(0x111718), color(0x0D1113)] as CFArray,
                            locations: [0, 0.65, 1])!
context.drawRadialGradient(atmosphere, startCenter: CGPoint(x: 320, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 450, y: 550), endRadius: 900,
                           options: [.drawsAfterEndLocation])
context.setLineCap(.round)
context.setLineWidth(49)
context.setStrokeColor(color(0xD6F58B))
context.addArc(center: CGPoint(x: 512, y: 512), radius: 300,
               startAngle: -.pi * 0.25, endAngle: .pi * 1.28, clockwise: false)
context.strokePath()
context.setStrokeColor(color(0xF2F1EA))
context.addArc(center: CGPoint(x: 512, y: 512), radius: 171,
               startAngle: -.pi * 0.06, endAngle: .pi * 1.40, clockwise: false)
context.strokePath()
let image = context.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: image)
let data = bitmap.representation(using: .png, properties: [:])!
let output = CommandLine.arguments.dropFirst().first
    ?? "iOS/Form/Assets.xcassets/AppIcon.appiconset/FormIcon.png"
try data.write(to: URL(fileURLWithPath: output), options: .atomic)
