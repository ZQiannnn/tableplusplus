// Renders the app icon (orange→teal gradient squircle + database cylinder)
// to a 1024×1024 PNG. Pure CoreGraphics, headless-safe.
// Usage: ICON_OUT=<out.png> swift scripts/render-icon.swift

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let out = ProcessInfo.processInfo.environment["ICON_OUT"] ?? "icon_1024.png"
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

let s = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

let inset: CGFloat = 88
let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let radius = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    CGColor(red: 0xF7 / 255, green: 0x8D / 255, blue: 0x11 / 255, alpha: 1),
    CGColor(red: 0x00 / 255, green: 0x75 / 255, blue: 0x8F / 255, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
// topLeading → bottomTrailing (CG origin is bottom-left)
ctx.drawLinearGradient(
    grad,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)
ctx.restoreGState()

// Database cylinder, white.
let cw = rect.width * 0.46
let cx = rect.midX
let bodyH = rect.height * 0.34
let ellipseH = cw * 0.34
let top = rect.midY + bodyH / 2
let bottom = rect.midY - bodyH / 2
let left = cx - cw / 2

func ellipse(_ centerY: CGFloat) -> CGRect {
    CGRect(x: left, y: centerY - ellipseH / 2, width: cw, height: ellipseH)
}

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))

// body
ctx.fill(CGRect(x: left, y: bottom, width: cw, height: bodyH))
// bottom cap
ctx.fillEllipse(in: ellipse(bottom))
// top cap
ctx.fillEllipse(in: ellipse(top))

// rings (gradient-colored grooves)
ctx.setStrokeColor(CGColor(red: 0x00 / 255, green: 0x75 / 255, blue: 0x8F / 255, alpha: 0.55))
ctx.setLineWidth(rect.width * 0.018)
for f in [0.34, 0.66] as [CGFloat] {
    let y = bottom + bodyH * f
    ctx.addEllipse(in: ellipse(y))
    ctx.strokePath()
}

guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no destination")
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out)")
