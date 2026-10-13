// Draws the app icon (Blueprint style) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let navy = rgb(0x0F1D38), gridMinor = rgb(0x1A3060), gridMajor = rgb(0x24427E)
let cobalt = rgb(0x2E6BFF), sky = rgb(0x8FB8FF), paper = rgb(0xEAF1FF)
let checkA = rgb(0x1A2D55), checkB = rgb(0x2A4580)

/// Draws in a 1024-unit space scaled to `px`.
func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)

    // macOS icon grid: 824 × 824 body, corner radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(shape); ctx.setFillColor(navy); ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Drafting grid.
    for i in 0...20 {
        let v = 100 + CGFloat(i) * 41.2
        ctx.setStrokeColor(i % 5 == 0 ? gridMajor : gridMinor)
        ctx.setLineWidth(i % 5 == 0 ? 3 : 2)
        ctx.move(to: CGPoint(x: v, y: 100)); ctx.addLine(to: CGPoint(x: v, y: 924))
        ctx.move(to: CGPoint(x: 100, y: v)); ctx.addLine(to: CGPoint(x: 924, y: v))
        ctx.strokePath()
    }

    // The "photo": left half original (paper), right half cut out (checkerboard).
    let card = CGRect(x: 262, y: 262, width: 500, height: 500)
    let mid = card.midX
    ctx.setFillColor(paper); ctx.fill(CGRect(x: card.minX, y: card.minY, width: mid - card.minX, height: card.height))
    let cell: CGFloat = 50
    for r in 0..<10 {
        for c in 0..<5 {
            ctx.setFillColor((r + c).isMultiple(of: 2) ? checkA : checkB)
            ctx.fill(CGRect(x: mid + CGFloat(c) * cell, y: card.minY + CGFloat(r) * cell, width: cell, height: cell))
        }
    }

    // Subject silhouette (head + shoulders) in cobalt, spanning both halves.
    ctx.saveGState()
    ctx.clip(to: card)
    ctx.setFillColor(cobalt)
    ctx.fillEllipse(in: CGRect(x: card.midX - 92, y: card.minY + 255, width: 184, height: 184))
    let shoulders = CGMutablePath()
    shoulders.move(to: CGPoint(x: card.minX + 70, y: card.minY))
    shoulders.addCurve(to: CGPoint(x: card.midX, y: card.minY + 235),
                       control1: CGPoint(x: card.minX + 80, y: card.minY + 170),
                       control2: CGPoint(x: card.midX - 150, y: card.minY + 235))
    shoulders.addCurve(to: CGPoint(x: card.maxX - 70, y: card.minY),
                       control1: CGPoint(x: card.midX + 150, y: card.minY + 235),
                       control2: CGPoint(x: card.maxX - 80, y: card.minY + 170))
    shoulders.closeSubpath()
    ctx.addPath(shoulders); ctx.fillPath()
    ctx.restoreGState()

    // Dashed cut line down the middle.
    ctx.setStrokeColor(paper); ctx.setLineWidth(8)
    ctx.setLineDash(phase: 0, lengths: [26, 18])
    ctx.move(to: CGPoint(x: mid, y: card.minY - 40)); ctx.addLine(to: CGPoint(x: mid, y: card.maxY + 40))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Crop marks around the card.
    ctx.setStrokeColor(sky); ctx.setLineWidth(10); ctx.setLineCap(.square)
    let gap: CGFloat = 26, len: CGFloat = 70
    for (x, y, dx, dy) in [(card.minX, card.minY, -1.0, -1.0), (card.maxX, card.minY, 1.0, -1.0),
                           (card.minX, card.maxY, -1.0, 1.0), (card.maxX, card.maxY, 1.0, 1.0)] {
        ctx.move(to: CGPoint(x: x + dx * gap, y: y)); ctx.addLine(to: CGPoint(x: x + dx * (gap + len), y: y))
        ctx.move(to: CGPoint(x: x, y: y + dy * gap)); ctx.addLine(to: CGPoint(x: x, y: y + dy * (gap + len)))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape); ctx.setStrokeColor(gridMajor); ctx.setLineWidth(4); ctx.strokePath()
    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(px: px))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
// Also keep a PNG preview next to it.
try NSBitmapImageRep(cgImage: render(px: 1024)).representation(using: .png, properties: [:])!
    .write(to: resources.appendingPathComponent("AppIcon.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
