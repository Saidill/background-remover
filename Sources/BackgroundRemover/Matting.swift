import CoreGraphics
import CoreImage
import Foundation

// Full-resolution, CPU-side compositing. Pixels that aren't changed (the subject, or everything in
// Keep mode) are copied byte-for-byte from the decoded original.

/// A single-channel float image. Manually managed so it can be filled from many threads.
final class Plane: @unchecked Sendable {
    let count: Int
    let p: UnsafeMutablePointer<Float>

    init(_ count: Int) {
        self.count = count
        p = .allocate(capacity: count)
    }

    convenience init(_ count: Int, _ f: (Int) -> Float) {
        self.init(count)
        let p = self.p
        parallelFor(count) { range in for i in range { p[i] = f(i) } }
    }

    deinit { p.deallocate() }

    @inline(__always) subscript(i: Int) -> Float { p[i] }
}

@inline(__always) func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }

/// Splits `0..<count` into chunks and runs them on all cores.
func parallelFor(_ count: Int, _ body: (Range<Int>) -> Void) {
    let chunks = max(1, min(count, ProcessInfo.processInfo.activeProcessorCount * 4))
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        body((count * c / chunks)..<(count * (c + 1) / chunks))
    }
}

protocol PixelComponent: FixedWidthInteger & UnsignedInteger {
    static var maxF: Float { get }
}
extension UInt8: PixelComponent { static var maxF: Float { 255 } }
extension UInt16: PixelComponent { static var maxF: Float { 65535 } }

/// The source's pixels exactly as decoded, repacked to RGBA — no color processing.
struct RawImage: @unchecked Sendable {
    let width: Int
    let height: Int
    let is16: Bool
    let opaque: Bool
    let premultiplied: Bool
    let colorSpace: CGColorSpace
    let raw8: [UInt8]   // RGBA, used when !is16
    let raw16: [UInt16] // RGBA, used when is16

    var count: Int { width * height }

    /// Component `i` (index into the RGBA array) as 0...1.
    @inline(__always) func comp(_ i: Int) -> Float {
        is16 ? Float(raw16[i]) / 65535 : Float(raw8[i]) / 255
    }

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        let src = image.colorSpace

        // Preferred path: take the decoder's bytes verbatim. (Drawing into a CGContext re-processes
        // the image — even in the same color space it can shift JPEG pixels by dozens of levels.)
        if src?.model == .rgb, let direct = RawImage.readDirect(image) {
            colorSpace = src!
            is16 = direct.is16
            raw8 = direct.raw8
            raw16 = direct.raw16
            opaque = direct.opaque
            premultiplied = direct.premultiplied
            return
        }

        // Fallback (grayscale, CMYK, float, exotic layouts): convert via CGContext.
        colorSpace = (src?.model == .rgb ? src : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        is16 = image.bitsPerComponent > 8
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        premultiplied = !opaque
        var bitmapInfo = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        if is16 { bitmapInfo |= CGBitmapInfo.byteOrder16Little.rawValue }
        let n = width * height
        var raw8 = [UInt8](), raw16 = [UInt16]()
        let (width, height, colorSpace) = (self.width, self.height, self.colorSpace)
        let draw = { (ptr: UnsafeMutableRawPointer, bpc: Int, rowBytes: Int) throws in
            guard let ctx = CGContext(data: ptr, width: width, height: height, bitsPerComponent: bpc,
                                      bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo)
            else { throw ImageError.renderFailed }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if is16 {
            raw16 = [UInt16](repeating: 0, count: n * 4)
            try raw16.withUnsafeMutableBytes { try draw($0.baseAddress!, 16, width * 8) }
        } else {
            raw8 = [UInt8](repeating: 0, count: n * 4)
            try raw8.withUnsafeMutableBytes { try draw($0.baseAddress!, 8, width * 4) }
        }
        self.raw8 = raw8
        self.raw16 = raw16
    }

    private struct Direct {
        var raw8 = [UInt8](), raw16 = [UInt16]()
        var is16: Bool, opaque: Bool, premultiplied: Bool
    }

    /// Repacks the CGImage's own pixel bytes into RGBA. Returns nil for layouts it doesn't understand.
    private static func readDirect(_ image: CGImage) -> Direct? {
        let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        let info = image.bitmapInfo
        guard bpc == 8 || bpc == 16, !info.contains(.floatComponents),
              let data = image.dataProvider?.data as Data? else { return nil }

        let alpha = image.alphaInfo
        let order: [Int] // logical component order: R=0, G=1, B=2, A=3, padding=-1
        switch alpha {
        case .none: order = [0, 1, 2]
        case .noneSkipLast: order = [0, 1, 2, -1]
        case .noneSkipFirst: order = [-1, 0, 1, 2]
        case .premultipliedLast, .last: order = [0, 1, 2, 3]
        case .premultipliedFirst, .first: order = [3, 0, 1, 2]
        default: return nil
        }
        guard bpp == bpc * order.count else { return nil }

        let byteOrder = CGImageByteOrderInfo(rawValue: info.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        if bpc == 8 && byteOrder != .orderDefault && byteOrder != .order32Big && byteOrder != .order32Little { return nil }
        if bpc == 16 && byteOrder != .orderDefault && byteOrder != .order16Little && byteOrder != .order16Big { return nil }
        let memOrder = (bpc == 8 && byteOrder == .order32Little && order.count == 4) ? order.reversed() : order
        let little16 = bpc == 16 && byteOrder == .order16Little

        let w = image.width, h = image.height, rowBytes = image.bytesPerRow
        let comps = order.count, hasAlpha = order.contains(3)
        var out = Direct(is16: bpc == 16, opaque: !hasAlpha,
                         premultiplied: alpha == .premultipliedLast || alpha == .premultipliedFirst)

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let base = buf.baseAddress!
            if bpc == 8 {
                var dst = [UInt8](repeating: 255, count: w * h * 4)
                dst.withUnsafeMutableBufferPointer { d in
                    let d = d.baseAddress!
                    parallelFor(h) { rows in
                        for y in rows {
                            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                            for x in 0..<w {
                                let s = row + x * comps, o = d + (y * w + x) * 4
                                for k in 0..<comps where memOrder[k] >= 0 { o[memOrder[k]] = s[k] }
                            }
                        }
                    }
                }
                out.raw8 = dst
            } else {
                var dst = [UInt16](repeating: 65535, count: w * h * 4)
                dst.withUnsafeMutableBufferPointer { d in
                    let d = d.baseAddress!
                    parallelFor(h) { rows in
                        for y in rows {
                            let row = base.advanced(by: y * rowBytes)
                            for x in 0..<w {
                                let o = d + (y * w + x) * 4
                                for k in 0..<comps where memOrder[k] >= 0 {
                                    let v = row.loadUnaligned(fromByteOffset: (x * comps + k) * 2, as: UInt16.self)
                                    o[memOrder[k]] = little16 ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
                                }
                            }
                        }
                    }
                }
                out.raw16 = dst
            }
        }
        return out
    }
}

/// Float color planes + the refined subject mask. Only built when Remove/Color is used.
final class Matte: @unchecked Sendable {
    let r: Plane, g: Plane, b: Plane // unpremultiplied, 0...1
    let a: Plane?                    // source alpha; nil when the source is opaque
    let baseAlpha: Plane

    init(source: SourceImage, raw: RawImage) throws {
        let n = raw.count, w = raw.width, h = raw.height
        let a: Plane? = raw.opaque ? nil : Plane(n) { raw.comp($0 * 4 + 3) }
        let premul = raw.premultiplied
        let unpremul: (Int, Int) -> Float = { i, c in
            let v = raw.comp(i * 4 + c)
            guard premul, let a else { return v }
            return a[i] > 0 ? clamp01(v / a[i]) : 0
        }
        let r = Plane(n) { unpremul($0, 0) }
        let g = Plane(n) { unpremul($0, 1) }
        let b = Plane(n) { unpremul($0, 2) }
        (self.r, self.g, self.b, self.a) = (r, g, b, a)

        let mask = try Segmenter.mask(for: source)
        let coarse = Matting.maskPlane(mask, w: w, h: h)
        let luma = Plane(n) { i in 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i] } // freed after refine
        baseAlpha = Matting.refine(mask: coarse, guide: luma, w: w, h: h)
    }
}

enum Matting {
    /// Mean filter with window (2r+1)², edge-normalized. Separable running sums, multithreaded.
    static func boxBlur(_ src: Plane, w: Int, h: Int, r: Int) -> Plane {
        let tmp = Plane(w * h), dst = Plane(w * h)
        let s = src.p, t = tmp.p, d = dst.p

        parallelFor(h) { rows in
            for y in rows {
                let row = s + y * w, out = t + y * w
                var sum = 0.0
                for x in 0...min(r, w - 1) { sum += Double(row[x]) }
                for x in 0..<w {
                    out[x] = Float(sum / Double(min(w - 1, x + r) - max(0, x - r) + 1))
                    if x + r + 1 < w { sum += Double(row[x + r + 1]) }
                    if x - r >= 0 { sum -= Double(row[x - r]) }
                }
            }
        }

        parallelFor(w) { cols in
            let x0 = cols.lowerBound, cw = cols.count
            guard cw > 0 else { return }
            var sums = [Double](repeating: 0, count: cw)
            for y in 0...min(r, h - 1) {
                let row = t + y * w + x0
                for i in 0..<cw { sums[i] += Double(row[i]) }
            }
            for y in 0..<h {
                let inv = 1.0 / Double(min(h - 1, y + r) - max(0, y - r) + 1)
                let out = d + y * w + x0
                for i in 0..<cw { out[i] = Float(sums[i] * inv) }
                if y + r + 1 < h {
                    let row = t + (y + r + 1) * w + x0
                    for i in 0..<cw { sums[i] += Double(row[i]) }
                }
                if y - r >= 0 {
                    let row = t + (y - r) * w + x0
                    for i in 0..<cw { sums[i] -= Double(row[i]) }
                }
            }
        }
        return dst
    }

    /// Converts Vision's mask (CIImage, same size as the source) to a float plane.
    static func maskPlane(_ mask: CIImage, w: Int, h: Int) -> Plane {
        let plane = Plane(w * h)
        Compositor.context.render(mask, toBitmap: plane.p, rowBytes: w * 4,
                                  bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                  format: .Rf, colorSpace: nil)
        return plane
    }

    /// Guided filter (He et al.): snaps the coarse, upscaled Vision mask onto real image edges.
    static func refine(mask p: Plane, guide I: Plane, w: Int, h: Int) -> Plane {
        let n = w * h
        let r = max(2, max(w, h) / 400)
        let eps: Float = 1e-4
        let meanI = boxBlur(I, w: w, h: h, r: r)
        let meanP = boxBlur(p, w: w, h: h, r: r)
        let corrIp = boxBlur(Plane(n) { I[$0] * p[$0] }, w: w, h: h, r: r)
        let corrII = boxBlur(Plane(n) { I[$0] * I[$0] }, w: w, h: h, r: r)
        let a = Plane(n) { i in
            let varI = corrII[i] - meanI[i] * meanI[i]
            let cov = corrIp[i] - meanI[i] * meanP[i]
            return cov / (varI + eps)
        }
        let b = Plane(n) { i in meanP[i] - a[i] * meanI[i] }
        let ma = boxBlur(a, w: w, h: h, r: r)
        let mb = boxBlur(b, w: w, h: h, r: r)
        return Plane(n) { i in clamp01(ma[i] * I[i] + mb[i]) }
    }

    /// `crisp` 1 (soft) … 4 (razor sharp); `trim` 0 … 0.4 pulls the edge inward to kill halos.
    static func adjust(_ base: Plane, crisp: Double, trim: Double) -> Plane {
        let k = Float(crisp), t = Float(trim)
        return Plane(base.count) { i in
            let v = clamp01((base[i] - 0.5 - t) * k + 0.5)
            return v < 1.0 / 255 ? 0 : (v > 254.0 / 255 ? 1 : v)
        }
    }

    /// Blur-Fusion foreground estimation (Forte & Pitié 2021): recovers the subject's true color at
    /// semi-transparent edge pixels, removing the old background that bleeds in.
    static func foreground(_ m: Matte, alpha: Plane, w: Int, h: Int) -> [Plane] {
        let n = w * h
        let scale = Double(max(w, h)) / 2000
        let radii = [max(15, Int(90 * scale)), max(3, Int(6 * scale))]
        let I = [m.r, m.g, m.b]
        var F = I, B = I
        for r in radii {
            let ba = boxBlur(alpha, w: w, h: h, r: r)
            var newF = [Plane](), newB = [Plane]()
            for c in 0..<3 {
                let (Fc, Bc, Ic) = (F[c], B[c], I[c])
                let bFA = boxBlur(Plane(n) { Fc[$0] * alpha[$0] }, w: w, h: h, r: r)
                let bBA = boxBlur(Plane(n) { Bc[$0] * (1 - alpha[$0]) }, w: w, h: h, r: r)
                let fb = Plane(n) { bFA[$0] / (ba[$0] + 1e-5) }
                let bb = Plane(n) { bBA[$0] / ((1 - ba[$0]) + 1e-5) }
                newF.append(Plane(n) { i in
                    let a = alpha[i]
                    return clamp01(fb[i] + a * (Ic[i] - a * fb[i] - (1 - a) * bb[i]))
                })
                newB.append(bb)
            }
            F = newF
            B = newB
        }
        return F
    }

    enum AlphaMode { case opaque, straight, premultiplied }

    /// Builds the final image at the source's exact size, color space and bit depth.
    /// `matte` is nil for Keep mode. `watermark` is a premultiplied RGBA8 layer in raw pixel layout.
    static func compose(_ raw: RawImage, matte: (m: Matte, alpha: Plane, fg: [Plane])?,
                        background: Background, watermark: [UInt8]?) throws -> CGImage {
        var bg: [Float] = [0, 0, 0]
        let mode: AlphaMode
        switch background {
        case .keep:
            mode = raw.opaque ? .opaque : (raw.premultiplied ? .premultiplied : .straight)
        case .transparent:
            mode = .straight
        case .color(let c):
            mode = .opaque
            if let comps = c.converted(to: raw.colorSpace, intent: .relativeColorimetric, options: nil)?.components,
               comps.count >= 3 {
                bg = comps.prefix(3).map { Float($0) }
            }
        }

        // (r, g, b, a) in 0...1 for a computed pixel, or nil = copy the original pixel exactly.
        var pixel: (Int) -> (Float, Float, Float, Float)? = { _ in nil }
        if let (m, alpha, F) = matte {
            let opaqueSrc = raw.opaque
            let transparent = mode == .straight
            pixel = { i in
                let k = alpha[i]
                if k >= 1 && opaqueSrc { return nil }
                let e = k * (m.a?[i] ?? 1) // effective coverage
                let (fr, fg, fb) = k >= 1 ? (m.r[i], m.g[i], m.b[i]) : (F[0][i], F[1][i], F[2][i])
                if transparent { return e <= 0 ? (0, 0, 0, 0) : (fr, fg, fb, e) }
                return (fr * e + bg[0] * (1 - e), fg * e + bg[1] * (1 - e), fb * e + bg[2] * (1 - e), 1)
            }
        }

        let data = raw.is16
            ? build(raw.raw16, raw: raw, mode: mode, pixel: pixel, watermark: watermark)
            : build(raw.raw8, raw: raw, mode: mode, pixel: pixel, watermark: watermark)

        var info: UInt32
        switch mode {
        case .opaque: info = CGImageAlphaInfo.noneSkipLast.rawValue
        case .straight: info = CGImageAlphaInfo.last.rawValue
        case .premultiplied: info = CGImageAlphaInfo.premultipliedLast.rawValue
        }
        if raw.is16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let bpc = raw.is16 ? 16 : 8
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: raw.width, height: raw.height, bitsPerComponent: bpc, bitsPerPixel: bpc * 4,
                               bytesPerRow: raw.width * bpc / 2, space: raw.colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImageError.renderFailed }
        return cg
    }

    private static func build<T: PixelComponent>(_ src: [T], raw: RawImage, mode: AlphaMode,
                                                 pixel: (Int) -> (Float, Float, Float, Float)?,
                                                 watermark: [UInt8]?) -> Data {
        let n = raw.count
        let maxV = T.maxF
        let forceOpaqueAlpha = raw.opaque || mode == .opaque
        var out = [T](repeating: 0, count: n * 4)
        out.withUnsafeMutableBufferPointer { o in
            let o = o.baseAddress!
            src.withUnsafeBufferPointer { s in
                let s = s.baseAddress!
                @inline(__always) func q(_ v: Float) -> T { T(clamp01(v) * maxV + 0.5) }
                parallelFor(n) { range in
                    for i in range {
                        let j = i * 4
                        if let (r, g, b, a) = pixel(i) {
                            o[j] = q(r); o[j + 1] = q(g); o[j + 2] = q(b); o[j + 3] = q(a)
                        } else {
                            o[j] = s[j]; o[j + 1] = s[j + 1]; o[j + 2] = s[j + 2]
                            o[j + 3] = forceOpaqueAlpha ? T(maxV) : s[j + 3]
                        }
                    }
                }
                guard let watermark else { return }
                watermark.withUnsafeBufferPointer { w in
                    let w = w.baseAddress!
                    parallelFor(n) { range in
                        for i in range {
                            let j = i * 4
                            let wa = Float(w[j + 3]) / 255
                            if wa == 0 { continue } // untouched pixels stay byte-identical
                            let wc = (Float(w[j]) / 255, Float(w[j + 1]) / 255, Float(w[j + 2]) / 255)
                            let oc = (Float(o[j]) / maxV, Float(o[j + 1]) / maxV, Float(o[j + 2]) / maxV)
                            let oa = Float(o[j + 3]) / maxV
                            switch mode {
                            case .opaque:
                                o[j] = q(wc.0 + oc.0 * (1 - wa)); o[j + 1] = q(wc.1 + oc.1 * (1 - wa))
                                o[j + 2] = q(wc.2 + oc.2 * (1 - wa))
                            case .premultiplied:
                                o[j] = q(wc.0 + oc.0 * (1 - wa)); o[j + 1] = q(wc.1 + oc.1 * (1 - wa))
                                o[j + 2] = q(wc.2 + oc.2 * (1 - wa)); o[j + 3] = q(wa + oa * (1 - wa))
                            case .straight:
                                let na = wa + oa * (1 - wa)
                                let k = oa * (1 - wa)
                                o[j] = q((wc.0 + oc.0 * k) / na); o[j + 1] = q((wc.1 + oc.1 * k) / na)
                                o[j + 2] = q((wc.2 + oc.2 * k) / na); o[j + 3] = q(na)
                            }
                        }
                    }
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}

/// Everything computed for one image, cached across edits so tweaks stay fast.
/// The matte (Vision + float planes, the heavy part) is only built when first needed.
final class EditSession: @unchecked Sendable {
    let source: SourceImage
    let raw: RawImage

    private var matte: Matte?
    private var cachedKey: (Double, Double)?
    private var cachedAlpha: Plane?
    private var cachedFG: [Plane]?
    private let lock = NSLock()

    init(source: SourceImage) throws {
        self.source = source
        raw = try RawImage(source.cgImage)
    }

    var hasMatte: Bool {
        lock.lock()
        defer { lock.unlock() }
        return matte != nil
    }

    func prepareMatte() throws {
        lock.lock()
        defer { lock.unlock() }
        if matte == nil { matte = try Matte(source: source, raw: raw) }
    }

    func render(background: Background, crisp: Double, trim: Double,
                watermark: WatermarkSettings?) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        let layer = watermark.flatMap { WatermarkRenderer.layer($0, source: source, colorSpace: raw.colorSpace) }

        if case .keep = background {
            return try Matting.compose(raw, matte: nil, background: background, watermark: layer)
        }
        if matte == nil { matte = try Matte(source: source, raw: raw) }
        let m = matte!
        if cachedKey.map({ $0 != (crisp, trim) }) ?? true {
            cachedFG = nil
            let alpha = Matting.adjust(m.baseAlpha, crisp: crisp, trim: trim)
            cachedFG = Matting.foreground(m, alpha: alpha, w: raw.width, h: raw.height)
            cachedAlpha = alpha
            cachedKey = (crisp, trim)
        }
        return try Matting.compose(raw, matte: (m, cachedAlpha!, cachedFG!), background: background, watermark: layer)
    }
}
