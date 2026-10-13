import CoreImage
import Vision

enum Segmenter {
    /// Returns a full-resolution foreground mask aligned with the source's *raw* pixels
    /// (same width × height as `source.cgImage`, origin at zero).
    static func mask(for source: SourceImage) throws -> CIImage {
        let orientation = source.orientation
        // Vision works best on an upright image, so segment in display orientation...
        let upright = CIImage(cgImage: source.cgImage).oriented(orientation)

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: upright, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty
        else { throw ImageError.noSubject }

        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler)
        let uprightMask = CIImage(cvPixelBuffer: buffer)

        // ...then rotate the mask back so it lines up with the stored pixels.
        let mask = uprightMask.oriented(orientation.inverse)
        return mask.transformed(by: CGAffineTransform(
            translationX: -mask.extent.origin.x, y: -mask.extent.origin.y))
    }
}

extension CGImagePropertyOrientation {
    var inverse: CGImagePropertyOrientation {
        switch self {
        case .left: return .right
        case .right: return .left
        default: return self // 180° turns, flips and transpositions are self-inverse
        }
    }
}
