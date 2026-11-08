#!/usr/bin/env swift
// Renders the DiskScout app icon (a disk with a scout's compass needle) to an .icns.
//   swift Scripts/make-icon.swift build/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DiskScout.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = r.insetBy(dx: size * 0.06, dy: size * 0.06)
    let radius = size * 0.22
    // Background squircle gradient
    let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.09, green: 0.11, blue: 0.27, alpha: 1).cgColor,
                  NSColor(red: 0.26, green: 0.15, blue: 0.48, alpha: 1).cgColor,
                  NSColor(red: 0.08, green: 0.32, blue: 0.50, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: inset.minX, y: inset.maxY), end: CGPoint(x: inset.maxX, y: inset.minY), options: [])
    // Glow blobs
    func glow(_ c: NSColor, at p: CGPoint, r: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
    }
    glow(NSColor(red: 0.74, green: 0.47, blue: 1.0, alpha: 0.55), at: CGPoint(x: inset.minX + size * 0.12, y: inset.minY + size * 0.12), r: size * 0.55)
    glow(NSColor(red: 0.27, green: 0.72, blue: 0.95, alpha: 0.45), at: CGPoint(x: inset.maxX - size * 0.12, y: inset.maxY - size * 0.1), r: size * 0.55)
    ctx.restoreGState()

    // Ring (disk usage) — track
    let center = CGPoint(x: size / 2, y: size / 2)
    let ringR = size * 0.30
    let lw = size * 0.085
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.addArc(center: center, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    // Ring — filled portion (green → mint)
    ctx.setStrokeColor(NSColor(red: 0.25, green: 0.85, blue: 0.5, alpha: 1).cgColor)
    ctx.addArc(center: center, radius: ringR, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.45, clockwise: true)
    ctx.strokePath()
    // Center disk
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - ringR * 0.62, y: center.y - ringR * 0.62, width: ringR * 1.24, height: ringR * 1.24))
    // Checkmark shield glyph in the middle
    let check = NSBezierPath()
    check.lineWidth = size * 0.07
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: CGPoint(x: center.x - ringR * 0.34, y: center.y + ringR * 0.02))
    check.line(to: CGPoint(x: center.x - ringR * 0.08, y: center.y - ringR * 0.26))
    check.line(to: CGPoint(x: center.x + ringR * 0.38, y: center.y + ringR * 0.28))
    NSColor.white.setStroke()
    check.stroke()
    // Sparkle
    func sparkle(at p: CGPoint, r: CGFloat) {
        let s = NSBezierPath()
        s.move(to: CGPoint(x: p.x, y: p.y + r))
        s.curve(to: CGPoint(x: p.x + r, y: p.y), controlPoint1: CGPoint(x: p.x + r * 0.15, y: p.y + r * 0.15), controlPoint2: CGPoint(x: p.x + r * 0.15, y: p.y + r * 0.15))
        s.curve(to: CGPoint(x: p.x, y: p.y - r), controlPoint1: CGPoint(x: p.x + r * 0.15, y: p.y - r * 0.15), controlPoint2: CGPoint(x: p.x + r * 0.15, y: p.y - r * 0.15))
        s.curve(to: CGPoint(x: p.x - r, y: p.y), controlPoint1: CGPoint(x: p.x - r * 0.15, y: p.y - r * 0.15), controlPoint2: CGPoint(x: p.x - r * 0.15, y: p.y - r * 0.15))
        s.curve(to: CGPoint(x: p.x, y: p.y + r), controlPoint1: CGPoint(x: p.x - r * 0.15, y: p.y + r * 0.15), controlPoint2: CGPoint(x: p.x - r * 0.15, y: p.y + r * 0.15))
        NSColor(red: 1, green: 0.88, blue: 0.45, alpha: 1).setFill()
        s.fill()
    }
    sparkle(at: CGPoint(x: center.x + ringR * 1.05, y: center.y + ringR * 1.0), r: size * 0.075)
    sparkle(at: CGPoint(x: center.x + ringR * 1.35, y: center.y + ringR * 0.62), r: size * 0.04)
    img.unlockFocus()
    return img
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let img = render(CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", tmp.path, "-o", out]
task.launch(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
