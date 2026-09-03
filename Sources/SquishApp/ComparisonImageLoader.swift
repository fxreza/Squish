import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A decoded image ready to hand to a CALayer, plus the facts the comparison view
/// needs to lay it out.
///
/// `cgImage` may be smaller than `nativeSize` - very large images are downsampled for
/// display. Both sides of a comparison are always downsampled with the *same* pixel
/// cap, so neither side is ever made to look worse than the other by the viewer.
final class LoadedImage: @unchecked Sendable {
    let cgImage: CGImage
    /// Oriented pixel dimensions of the real file, whatever we chose to display.
    let nativeSize: CGSize
    let hasAlpha: Bool
    let isDownsampled: Bool
    let byteCount: Int64

    init(cgImage: CGImage, nativeSize: CGSize, hasAlpha: Bool, isDownsampled: Bool, byteCount: Int64) {
        self.cgImage = cgImage
        self.nativeSize = nativeSize
        self.hasAlpha = hasAlpha
        self.isDownsampled = isDownsampled
        self.byteCount = byteCount
    }
}

enum ComparisonImageLoader {

    /// Long edge, in pixels, of the largest texture we will hold in memory per side.
    /// A 48 MP original would otherwise cost ~190 MB per side as RGBA.
    static let displayPixelCap = 4096

    enum LoadError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't decode \(name)."
            }
        }
    }

    /// Decodes off the main thread. `maxPixelSize` of nil means "cap at
    /// `displayPixelCap`"; pass an explicit value to make a second image match a
    /// first one exactly.
    static func load(url: URL, maxPixelSize: Int? = nil) async throws -> LoadedImage {
        try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated static func loadSynchronously(url: URL, maxPixelSize: Int?) throws -> LoadedImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5-8 are the transposed ones: the file's stored width is the
        // displayed height. The compressed result always comes out upright, so the
        // original has to be uprighted too or the two sides would not even match.
        let transposed = orientation >= 5
        let nativeSize = CGSize(width: transposed ? pixelHeight : pixelWidth,
                                height: transposed ? pixelWidth : pixelHeight)

        let longEdge = max(pixelWidth, pixelHeight)
        let cap = maxPixelSize ?? displayPixelCap
        let requested = min(longEdge > 0 ? longEdge : cap, cap)

        // The thumbnail path is used even at full size, because it is the only ImageIO
        // entry point that applies the EXIF orientation transform for us.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requested,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let image: CGImage
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            image = thumb
        } else if let full = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = full
        } else {
            throw LoadError.unreadable(url.lastPathComponent)
        }

        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        return LoadedImage(cgImage: image,
                           nativeSize: nativeSize.width > 0 && nativeSize.height > 0
                               ? nativeSize
                               : CGSize(width: image.width, height: image.height),
                           hasAlpha: hasAlpha,
                           isDownsampled: requested < longEdge,
                           byteCount: bytes)
    }
}
