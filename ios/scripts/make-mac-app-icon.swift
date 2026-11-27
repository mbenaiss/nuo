// Renders the macOS app icon (the iPhone orb inside the macOS rounded-rect grid) into Mac/Assets.xcassets.
// Run: swift ios/scripts/make-mac-app-icon.swift
import AppKit

let source = NSImage(contentsOfFile: "ios/Nuo/Assets.xcassets/AppIcon.appiconset/AppIcon.png")!
let folder = "ios/Mac/Assets.xcassets/AppIcon.appiconset"

func render(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels)
    // Apple's macOS grid: an 824 pt body centred in 1024 with a ~185 pt corner radius and a soft drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset + s * 0.012, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: body)
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [String] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try! render(size * scale).write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
        images.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(size)x\#(size)" }"#)
    }
}
let json = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
