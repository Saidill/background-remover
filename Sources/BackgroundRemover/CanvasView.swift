import SwiftUI

/// The drafting table: grid paper, pixel rulers, crop marks, before/after split, loupe and
/// (in the Watermark tool) draggable watermark with snapping guides.
struct CanvasView: View {
    @ObservedObject var model: EditorModel
    let before: NSImage
    let pixelSize: CGSize // upright
    let loupeEnabled: Bool
    @Binding var cursor: CGPoint? // image pixel coordinates, for the status bar

    @State private var split: CGFloat = 0.5
    @State private var hover: CGPoint?
    @State private var dragOffset: CGSize?
    @State private var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)

    private let ruler: CGFloat = 22
    private let loupeSize: CGFloat = 180
    private var watermarkTool: Bool { model.tool == .watermark }
    private var showsSplit: Bool { !watermarkTool && model.afterImage != nil && model.mode != .keep }

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                BlueprintGrid()
                imageStack(fit: fit)
                CropMarks().stroke(Theme.sky, lineWidth: 1).frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                Rulers(fit: fit, pixelSize: pixelSize, thickness: ruler, cursor: hover.flatMap { fit.contains($0) ? $0 : nil })
                if showsSplit { divider(fit: fit); tags(fit: fit) }
                if watermarkTool { watermarkChrome(fit: fit) }
                if loupeEnabled, dragOffset == nil, let p = hover, fit.contains(p) {
                    loupe(at: p, fit: fit, container: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    hover = v.location
                    if watermarkTool { dragWatermark(v, fit: fit) }
                    else if showsSplit { split = min(1, max(0, (v.location.x - fit.minX) / fit.width)) }
                }
                .onEnded { _ in dragOffset = nil; guides = (nil, nil) })
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hover = p
                    cursor = fit.contains(p)
                        ? CGPoint(x: (p.x - fit.minX) / fit.width * pixelSize.width,
                                  y: (p.y - fit.minY) / fit.height * pixelSize.height) : nil
                } else { hover = nil; cursor = nil }
            }
        }
        .background(Theme.ink)
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let pad: CGFloat = 40
        let avail = CGRect(x: ruler + pad, y: ruler + pad,
                           width: size.width - ruler - pad * 2, height: size.height - ruler - pad * 2)
        let scale = min(avail.width / pixelSize.width, avail.height / pixelSize.height)
        let w = pixelSize.width * scale, h = pixelSize.height * scale
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    // MARK: Image layers

    @ViewBuilder
    private func imageStack(fit: CGRect) -> some View {
        let after = model.afterImage ?? before
        ZStack(alignment: .topLeading) {
            if model.mode == .remove { Checkerboard() }
            Image(nsImage: after).resizable().interpolation(.high)
            if let wm = model.watermarkPreview { Image(nsImage: wm).resizable().interpolation(.high) }
            if showsSplit {
                Image(nsImage: before).resizable().interpolation(.high)
                    .mask(alignment: .leading) { Rectangle().frame(width: fit.width * split) }
            }
            if model.isAnalyzing { Theme.ink.opacity(0.45) }
        }
        .frame(width: fit.width, height: fit.height)
        .overlay(Rectangle().strokeBorder(Theme.line))
        .offset(x: fit.minX, y: fit.minY)
    }

    private func divider(fit: CGRect) -> some View {
        let x = fit.minX + fit.width * split
        return ZStack {
            Rectangle().fill(Theme.accent).frame(width: 1.5, height: fit.height + 24)
            Rectangle().fill(Theme.accent).frame(width: 22, height: 22)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
        }
        .position(x: x, y: fit.midY)
        .allowsHitTesting(false)
    }

    private func tags(fit: CGRect) -> some View {
        HStack {
            Tag(text: "BEFORE").opacity(split > 0.15 ? 1 : 0)
            Spacer()
            Tag(text: "AFTER").opacity(split < 0.85 ? 1 : 0)
        }
        .frame(width: fit.width)
        .offset(x: fit.minX, y: fit.maxY + 10)
        .allowsHitTesting(false)
    }

    // MARK: Watermark

    @ViewBuilder
    private func watermarkChrome(fit: CGRect) -> some View {
        let s = model.watermark
        if s.isVisible && s.layout == .single {
            let scale = fit.width / pixelSize.width
            let b = WatermarkRenderer.blockSize(s, imageSize: pixelSize)
            let pad: CGFloat = 6
            Rectangle()
                .stroke(Theme.sky, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: b.width * scale + pad * 2, height: b.height * scale + pad * 2)
                .rotationEffect(.degrees(-s.rotation))
                .position(x: fit.minX + s.x * fit.width, y: fit.minY + s.y * fit.height)
                .allowsHitTesting(false)
        }
        Path { p in
            if let gx = guides.x {
                let x = fit.minX + gx * fit.width
                p.move(to: CGPoint(x: x, y: fit.minY - 12)); p.addLine(to: CGPoint(x: x, y: fit.maxY + 12))
            }
            if let gy = guides.y {
                let y = fit.minY + gy * fit.height
                p.move(to: CGPoint(x: fit.minX - 12, y: y)); p.addLine(to: CGPoint(x: fit.maxX + 12, y: y))
            }
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        .allowsHitTesting(false)
    }

    private func dragWatermark(_ v: DragGesture.Value, fit: CGRect) {
        guard model.watermark.isVisible, model.watermark.layout == .single else { return }
        let s = model.watermark
        let center = CGPoint(x: fit.minX + s.x * fit.width, y: fit.minY + s.y * fit.height)
        if dragOffset == nil {
            dragOffset = CGSize(width: center.x - v.startLocation.x, height: center.y - v.startLocation.y)
        }
        var nx = (v.location.x + dragOffset!.width - fit.minX) / fit.width
        var ny = (v.location.y + dragOffset!.height - fit.minY) / fit.height

        // Snap to center and to the margin-aligned edges (within 8 pt on screen).
        let tl = WatermarkRenderer.center(for: .topLeft, s, imageSize: pixelSize)
        let br = WatermarkRenderer.center(for: .bottomRight, s, imageSize: pixelSize)
        let threshold: CGFloat = 8
        var gx: CGFloat?, gy: CGFloat?
        for t in [0.5, tl.x, br.x] where abs(nx - t) * fit.width < threshold { nx = t; gx = t; break }
        for t in [0.5, tl.y, br.y] where abs(ny - t) * fit.height < threshold { ny = t; gy = t; break }
        guides = (gx, gy)
        model.watermark.x = min(1, max(0, nx))
        model.watermark.y = min(1, max(0, ny))
    }

    // MARK: Loupe

    /// Real pixels, no smoothing, at ≥ 2× — for checking edge sharpness.
    private func loupe(at p: CGPoint, fit: CGRect, container: CGSize) -> some View {
        let zoom = max(2, pixelSize.width / fit.width * 2)
        let onBefore = showsSplit && p.x < fit.minX + fit.width * split
        let image = onBefore ? before : (model.afterImage ?? before)
        let lx = p.x - fit.minX, ly = p.y - fit.minY
        let pos = CGPoint(
            x: min(max(p.x + loupeSize * 0.7, loupeSize / 2 + 8), container.width - loupeSize / 2 - 8),
            y: min(max(p.y - loupeSize * 0.7, loupeSize / 2 + 8), container.height - loupeSize / 2 - 30))

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.mode == .remove && !onBefore { Checkerboard() } else { Theme.ink }
                Image(nsImage: image).resizable().interpolation(.none)
                    .frame(width: fit.width * zoom, height: fit.height * zoom)
                    .offset(x: loupeSize / 2 - lx * zoom, y: loupeSize / 2 - ly * zoom)
            }
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            .clipped()
            .overlay(Path { path in
                let c = loupeSize / 2
                path.move(to: CGPoint(x: c - 10, y: c)); path.addLine(to: CGPoint(x: c + 10, y: c))
                path.move(to: CGPoint(x: c, y: c - 10)); path.addLine(to: CGPoint(x: c, y: c + 10))
            }.stroke(Theme.accent, lineWidth: 1))
            .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5))

            Text("\(onBefore ? "ORIGINAL" : "RESULT")  \(String(format: "%.1f", zoom / 2))×")
                .font(Theme.mono(9, .bold)).foregroundStyle(.white)
                .frame(width: loupeSize, height: 20).background(Theme.accent)
        }
        .position(pos)
        .allowsHitTesting(false)
    }
}

// MARK: - Pieces

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.mono(9, .bold)).tracking(1.5).foregroundStyle(Theme.sky)
            .padding(.horizontal, 6).frame(height: 18)
            .overlay(Rectangle().strokeBorder(Theme.line))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.checkA))
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(Theme.checkB))
                }
            }
        }
    }
}

/// Static drafting-paper grid (minor every 24 pt, major every 120 pt).
struct BlueprintGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var minor = Path(), major = Path()
            let step: CGFloat = 24
            for i in 0...Int(size.width / step) {
                let x = CGFloat(i) * step
                let pts = [CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)]
                if i % 5 == 0 { major.addLines(pts) } else { minor.addLines(pts) }
            }
            for i in 0...Int(size.height / step) {
                let y = CGFloat(i) * step
                let pts = [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
                if i % 5 == 0 { major.addLines(pts) } else { minor.addLines(pts) }
            }
            ctx.stroke(minor, with: .color(Theme.gridMinor), lineWidth: 1)
            ctx.stroke(major, with: .color(Theme.gridMajor), lineWidth: 1)
        }
    }
}

private extension Path {
    mutating func addLines(_ pts: [CGPoint]) { move(to: pts[0]); addLine(to: pts[1]) }
}

/// Top and left rulers in image pixel units, with a cursor marker.
struct Rulers: View {
    let fit: CGRect
    let pixelSize: CGSize
    let thickness: CGFloat
    let cursor: CGPoint?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: thickness)), with: .color(Theme.panel))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: thickness, height: size.height)), with: .color(Theme.panel))

            let ppp = pixelSize.width / fit.width // image pixels per point
            let major = niceStep(64 * ppp)
            let minor = major / 5
            var ticks = Path()
            var v: CGFloat = 0
            while v <= pixelSize.width + 0.5 {
                let x = fit.minX + v / ppp
                let isMajor = abs(v.truncatingRemainder(dividingBy: major)) < 0.001 || abs(v.truncatingRemainder(dividingBy: major) - major) < 0.001
                ticks.move(to: CGPoint(x: x, y: thickness)); ticks.addLine(to: CGPoint(x: x, y: thickness - (isMajor ? 9 : 4)))
                if isMajor {
                    ctx.draw(Text(verbatim: "\(Int(v))").font(Theme.mono(8)).foregroundColor(Theme.sky),
                             at: CGPoint(x: x + 3, y: 7), anchor: .leading)
                }
                v += minor
            }
            v = 0
            while v <= pixelSize.height + 0.5 {
                let y = fit.minY + v / ppp
                let isMajor = abs(v.truncatingRemainder(dividingBy: major)) < 0.001 || abs(v.truncatingRemainder(dividingBy: major) - major) < 0.001
                ticks.move(to: CGPoint(x: thickness, y: y)); ticks.addLine(to: CGPoint(x: thickness - (isMajor ? 9 : 4), y: y))
                if isMajor {
                    var c = ctx
                    c.translateBy(x: 7, y: y + 3)
                    c.rotate(by: .degrees(-90))
                    c.draw(Text(verbatim: "\(Int(v))").font(Theme.mono(8)).foregroundColor(Theme.sky), at: .zero, anchor: .trailing)
                }
                v += minor
            }
            ctx.stroke(ticks, with: .color(Theme.line), lineWidth: 1)

            // Image extent on the rulers.
            ctx.fill(Path(CGRect(x: fit.minX, y: thickness - 2, width: fit.width, height: 2)), with: .color(Theme.accent.opacity(0.6)))
            ctx.fill(Path(CGRect(x: thickness - 2, y: fit.minY, width: 2, height: fit.height)), with: .color(Theme.accent.opacity(0.6)))

            if let c = cursor {
                ctx.fill(Path(CGRect(x: c.x - 0.5, y: 0, width: 1, height: thickness)), with: .color(Theme.accent))
                ctx.fill(Path(CGRect(x: 0, y: c.y - 0.5, width: thickness, height: 1)), with: .color(Theme.accent))
            }
            ctx.fill(Path(CGRect(x: 0, y: 0, width: thickness, height: thickness)), with: .color(Theme.panel))
            ctx.stroke(Path(CGRect(x: 0, y: thickness - 0.5, width: size.width, height: 0)), with: .color(Theme.line))
            ctx.stroke(Path(CGRect(x: thickness - 0.5, y: 0, width: 0, height: size.height)), with: .color(Theme.line))
        }
        .allowsHitTesting(false)
    }

    private func niceStep(_ minimum: CGFloat) -> CGFloat {
        let exp = pow(10, floor(log10(max(minimum, 1))))
        for m in [1.0, 2.0, 5.0, 10.0] where m * exp >= minimum { return m * exp }
        return 10 * exp
    }
}
