import CoreGraphics
import CoreImage

enum Background: Sendable {
    case keep
    case transparent
    case color(CGColor)
}

enum Compositor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Upright copy for on-screen display only (saved files keep the raw pixels + orientation tag).
    /// Images without a rotation flag are shown pixel-for-pixel as-is.
    static func displayImage(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return cg }
        var upright = CIImage(cgImage: cg).oriented(orientation)
        upright = upright.transformed(by: CGAffineTransform(
            translationX: -upright.extent.origin.x, y: -upright.extent.origin.y))
        let format: CIFormat = cg.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        return context.createCGImage(upright, from: upright.extent, format: format,
                                     colorSpace: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) ?? cg
    }
}
