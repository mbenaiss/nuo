// Renders the app icon (orange orb on ink) into Assets.xcassets. Run: swift ios/scripts/make-app-icon.swift
import AppKit
import CoreGraphics

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ios/Nuo/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let s = CGFloat(size)
let background = CGGradient(colorsSpace: space, colors: [color(0x22222A), color(0x0E0E12)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

let center = CGPoint(x: s * 0.5, y: s * 0.5)
let radius = s * 0.30
let glow = CGGradient(colorsSpace: space, colors: [color(0xFF6A2B, 0.55), color(0xFF6A2B, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: radius * 0.8, endCenter: center, endRadius: radius * 1.65, options: [])

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.clip()
let orb = CGGradient(colorsSpace: space, colors: [color(0xFFE2C2), color(0xFF8A47), color(0xE2462A), color(0x7A1E3B)] as CFArray, locations: [0, 0.42, 0.75, 1])!
let highlight = CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.4)
ctx.drawRadialGradient(orb, startCenter: highlight, startRadius: 0, endCenter: center, endRadius: radius * 1.05, options: [.drawsAfterEndLocation])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
