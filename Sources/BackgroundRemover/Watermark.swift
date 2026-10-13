import AppKit
import CoreImage
import CoreText

/// All watermark parameters. Sizes are relative to the image, so the layout is identical
/// in the small on-screen preview and the full-resolution export.
struct WatermarkSettings: Equatable, Sendable {
    enum Layout: String, CaseIterable, Sendable { case single = "Single", tiled = "Tile" }

    var enabled = false
    var text = "CONFIDENTIAL"
    var fontName = "System"
    var bold = true
    var sizePercent = 8.0      // font size as % of the image's short side
    var opacity = 0.35
    var red = 1.0, green = 1.0, blue = 1.0 // sRGB
    var rotation = 0.0         // degrees, counter-clockwise
    var x = 0.5, y = 0.5       // normalized center, origin top-left
    var layout = Layout.single
    var spacing = 1.2          // gap between tiles, × font size
    var marginPercent = 4.0    // edge margin for auto-align, % of short side
    var outline = false

    static let builtInFonts = ["System", "Serif", "Rounded", "Mono"]

    var isVisible: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 3 × 3 auto-align positions.
enum WatermarkAlign: CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var anchor: (CGFloat, CGFloat) {
        let i = WatermarkAlign.allCases.firstIndex(of: self)!
        return (CGFloat(i % 3) / 2, CGFloat(i / 3) / 2)
    }
}

enum WatermarkRenderer {
    static func font(_ s: WatermarkSettings, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = s.bold ? .bold : .regular
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign?
        switch s.fontName {
        case "System": return system
        case "Serif": design = .serif
        case "Rounded": design = .rounded
        case "Mono": design = .monospaced
        default: design = nil
        }
        if let design, let d = system.fontDescriptor.withDesign(design) {
            return NSFont(descriptor: d, size: size) ?? system
        }
        return NSFontManager.shared.font(withFamily: s.fontName, traits: s.bold ? .boldFontMask : [],
                                         weight: s.bold ? 9 : 5, size: size) ?? system
    }

    private struct Block {
        let lines: [(CTLine, CGFloat)] // line + width
        let ascent: CGFloat
        let lineHeight: CGFloat
        let size: CGSize
        let fontSize: CGFloat
    }

    private static func block(_ s: WatermarkSettings, imageSize: CGSize) -> Block {
        let fs = max(1, CGFloat(s.sizePercent) / 100 * min(imageSize.width, imageSize.height))
        let f = font(s, size: fs)
        let color = CGColor(srgbRed: s.red, green: s.green, blue: s.blue, alpha: 1)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if s.outline {
            let luminance = 0.299 * s.red + 0.587 * s.green + 0.114 * s.blue
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                luminance > 0.5 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4.0
        }
        let lines = s.text.components(separatedBy: "\n").map { str -> (CTLine, CGFloat) in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
            return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        let ascent = f.ascender, descent = -f.descender
        let lineHeight = ascent + descent + f.leading
        let height = lineHeight * CGFloat(lines.count) - f.leading
        let width = lines.map(\.1).max() ?? 0
        return Block(lines: lines, ascent: ascent, lineHeight: lineHeight,
                     size: CGSize(width: width, height: height), fontSize: fs)
    }

    /// Unrotated text block size in image pixels.
    static func blockSize(_ s: WatermarkSettings, imageSize: CGSize) -> CGSize {
        block(s, imageSize: imageSize).size
    }

    /// Bounding box of the rotated block in image pixels.
    static func rotatedSize(_ s: WatermarkSettings, imageSize: CGSize) -> CGSize {
        let b = blockSize(s, imageSize: imageSize)
        let t = s.rotation * .pi / 180
        let c = abs(cos(t)), sn = abs(sin(t))
        return CGSize(width: b.width * c + b.height * sn, height: b.width * sn + b.height * c)
    }

    /// Normalized center that places the watermark at `align`, respecting the margin.
    static func center(for align: WatermarkAlign, _ s: WatermarkSettings, imageSize: CGSize) -> CGPoint {
        let rs = rotatedSize(s, imageSize: imageSize)
        let margin = CGFloat(s.marginPercent) / 100 * min(imageSize.width, imageSize.height)
        let (ax, ay) = align.anchor
        func pos(_ anchor: CGFloat, _ extent: CGFloat, _ total: CGFloat) -> CGFloat {
            if anchor == 0 { return margin + extent / 2 }
            if anchor == 1 { return total - margin - extent / 2 }
            return total / 2
        }
        return CGPoint(x: pos(ax, rs.width, imageSize.width) / imageSize.width,
                       y: pos(ay, rs.height, imageSize.height) / imageSize.height)
    }

    /// Draws the watermark into `ctx` (CoreGraphics coordinates, origin bottom-left) covering `size`.
    static func draw(_ s: WatermarkSettings, in ctx: CGContext, size: CGSize) {
        guard s.isVisible else { return }
        let b = block(s, imageSize: size)
        let angle = CGFloat(s.rotation) * .pi / 180

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.setAlpha(CGFloat(s.opacity))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil) // group opacity: fill + outline don't double up

        func drawBlock(at p: CGPoint) {
            var baseline = p.y + b.size.height / 2 - b.ascent
            for (line, width) in b.lines {
                ctx.textPosition = CGPoint(x: p.x - width / 2, y: baseline)
                CTLineDraw(line, ctx)
                baseline -= b.lineHeight
            }
        }

        switch s.layout {
        case .single:
            ctx.translateBy(x: CGFloat(s.x) * size.width, y: (1 - CGFloat(s.y)) * size.height)
            ctx.rotate(by: angle)
            drawBlock(at: .zero)
        case .tiled:
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: angle)
            let gap = CGFloat(s.spacing) * b.fontSize
            let stepX = b.size.width + gap, stepY = b.size.height + gap
            let reach = hypot(size.width, size.height) / 2 + max(stepX, stepY)
            let rows = Int(ceil(reach / stepY)), cols = Int(ceil(reach / stepX)) + 1
            for row in -rows...rows {
                let shift = row.isMultiple(of: 2) ? 0 : stepX / 2
                for col in -cols...cols {
                    drawBlock(at: CGPoint(x: CGFloat(col) * stepX + shift, y: CGFloat(row) * stepY))
                }
            }
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Small upright layer for the on-screen preview.
    static func preview(_ s: WatermarkSettings, uprightSize: CGSize, maxSide: CGFloat = 1800) -> CGImage? {
        guard s.isVisible else { return nil }
        let scale = min(1, maxSide / max(uprightSize.width, uprightSize.height))
        let w = max(1, Int(uprightSize.width * scale)), h = max(1, Int(uprightSize.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(s, in: ctx, size: CGSize(width: w, height: h))
        return ctx.makeImage()
    }

    /// Full-resolution premultiplied RGBA8 layer in the source's *raw* pixel layout (orientation undone),
    /// ready to composite over the output pixels.
    static func layer(_ s: WatermarkSettings, source: SourceImage, colorSpace: CGColorSpace) -> [UInt8]? {
        guard s.isVisible else { return nil }
        let up = source.uprightSize
        let uw = Int(up.width), uh = Int(up.height)
        var upright = [UInt8](repeating: 0, count: uw * uh * 4)
        let drawn: Bool = upright.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: uw, height: uh, bitsPerComponent: 8,
                                      bytesPerRow: uw * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            draw(s, in: ctx, size: up)
            return true
        }
        guard drawn else { return nil }
        let orientation = source.orientation
        if orientation == .up { return upright }

        // Rotate the layer back into the stored pixel layout (same mapping as the Vision mask).
        let w = source.width, h = source.height
        guard let provider = CGDataProvider(data: Data(upright) as CFData),
              let cg = CGImage(width: uw, height: uh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: uw * 4,
                               space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        var ci = CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).oriented(orientation.inverse)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            Compositor.context.render(ci, toBitmap: buf.baseAddress!, rowBytes: w * 4,
                                      bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                      format: .RGBA8, colorSpace: nil)
        }
        return out
    }
}
