import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageError: LocalizedError {
    case cannotRead
    case noSubject
    case renderFailed
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "Could not read this image."
        case .noSubject: return "No foreground subject was found in this image."
        case .renderFailed: return "Failed to render the edited image."
        case .cannotWrite: return "Could not save the image."
        }
    }
}

/// The original image exactly as stored on disk: raw (unrotated) pixels plus every metadata property.
struct SourceImage: @unchecked Sendable {
    let url: URL
    let cgImage: CGImage
    let properties: [CFString: Any]
    let type: UTType

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    var orientation: CGImagePropertyOrientation {
        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    var dpi: Double? {
        (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }

    var profileName: String? { properties[kCGImagePropertyProfileName] as? String }

    /// Pixel size as displayed (after applying the orientation tag).
    var uprightSize: CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return CGSize(width: height, height: width)
        default: return CGSize(width: width, height: height)
        }
    }

    static func load(from url: URL) throws -> SourceImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source),
              // No options: full resolution, no thumbnailing, no orientation transform.
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageError.cannotRead }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return SourceImage(
            url: url,
            cgImage: image,
            properties: props,
            type: UTType(typeID as String) ?? .png
        )
    }
}

enum ImageWriter {
    static let writableTypes: Set<String> = {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    static func supportsAlpha(_ type: UTType) -> Bool {
        type.conforms(to: .png) || type.conforms(to: .tiff) || type.conforms(to: .heic)
    }

    /// Formats the user can pick from in the save menu.
    static func choices(transparent: Bool) -> [UTType] {
        [UTType.png, .tiff, .heic, .jpeg].filter {
            writableTypes.contains($0.identifier) && (!transparent || supportsAlpha($0))
        }
    }

    /// Keep the original format whenever possible; switch to PNG only when transparency
    /// is required but the original format cannot store it (e.g. JPEG), or it is not writable.
    static func outputType(for source: SourceImage, transparent: Bool) -> UTType {
        let original = source.type
        guard writableTypes.contains(original.identifier) else { return .png }
        if transparent && !supportsAlpha(original) { return .png }
        return original
    }

    /// Writes `image` with all of the source's metadata (EXIF, GPS, TIFF, IPTC, DPI, orientation).
    static func write(_ image: CGImage, to url: URL, type: UTType, source: SourceImage) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw ImageError.cannotWrite }

        var props = source.properties
        // Pixel layout of `image` matches the source exactly, so orientation & DPI stay valid.
        props[kCGImagePropertyPixelWidth] = image.width
        props[kCGImagePropertyPixelHeight] = image.height
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
            // Maximum quality: lossy formats can't be bit-identical after any edit, but this is as close as it gets.
            props[kCGImageDestinationLossyCompressionQuality] = 1.0
        }

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.cannotWrite }
    }
}
