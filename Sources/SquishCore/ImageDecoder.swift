import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What came out of the file, once.
public struct DecodedImage: Sendable {
    public let pixels: PixelImage
    /// UTI reported by ImageIO, e.g. "public.jpeg", "com.canon.cr2-raw-image".
    public let sourceUTI: String?
    /// EXIF orientation as stored (1...8). Already applied to `pixels`.
    public let orientation: UInt32
    /// Source ICC profile, if the file had one.
    public let iccProfile: Data?
    /// The source's image-properties dictionary, flattened to a binary plist so the struct
    /// stays `Sendable`. Re-inflate with `metadataProperties()`.
    public let metadataPlist: Data?
    /// A ready-to-splice JPEG `APP1`/Exif segment (marker bytes included) built from the source
    /// metadata, or nil when there was nothing worth keeping. Used by the mozjpeg path, which
    /// cannot be handed a properties dictionary.
    public let exifAPP1: Data?
    public let isRAW: Bool

    public func metadataProperties() -> [String: Any]? {
        guard let data = metadataPlist else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

public enum ImageDecoder {

    /// Formats ImageIO can read. Used to filter directory walks.
    public static func isDecodable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        if type.conforms(to: .image) { return true }
        // Camera RAW types conform to public.camera-raw-image, which conforms to public.image,
        // but a few third-party declarations do not, so check explicitly too.
        return type.conforms(to: UTType("public.camera-raw-image") ?? .image)
    }

    /// Decodes `url` into the canonical RGBA8 buffer, applying EXIF orientation.
    ///
    /// - Parameter preserveColorSpace: with `--keep-metadata` the source RGB profile is kept and
    ///   the samples stay in it. Otherwise everything is converted to sRGB while drawing, which
    ///   is what the spec asks for ("ICC is always converted to sRGB on output").
    public static func decode(url: URL, preserveColorSpace: Bool) throws -> DecodedImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw SquishError.decodeFailed(url: url, reason: "ImageIO could not open the file")
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw SquishError.decodeFailed(url: url, reason: "no images in file")
        }

        let uti = CGImageSourceGetType(source) as String?
        let isRAW = uti.map { Self.isRawUTI($0) } ?? false
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32) ?? 1

        guard let cgImage = try makeFullSizeImage(source: source, properties: props, isRAW: isRAW, url: url) else {
            throw SquishError.decodeFailed(url: url, reason: "ImageIO returned no image")
        }

        let sourceICC = cgImage.colorSpace.flatMap { $0.copyICCData() as Data? }
        let keepICC = preserveColorSpace && (cgImage.colorSpace?.model == .rgb)
        let targetSpace: CGColorSpace = keepICC
            ? (cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

        // Thumbnail-based RAW decodes already have orientation baked in; CreateImageAtIndex
        // decodes do not.
        let effectiveOrientation = orientation
        let pixels = try rasterise(cgImage,
                                   orientation: effectiveOrientation,
                                   colorSpace: targetSpace,
                                   iccProfile: keepICC ? sourceICC : nil)

        var plist: Data?
        if !props.isEmpty {
            // Same reason as ExifSegment.normalisingOrientation: orientation is baked into the
            // pixels, so the metadata that rides along must claim orientation 1.
            var carried = sanitise(props)
            carried[kCGImagePropertyOrientation as String] = 1
            if var tiff = carried[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                carried[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            plist = try? PropertyListSerialization.data(fromPropertyList: carried,
                                                        format: .binary, options: 0)
        }

        return DecodedImage(pixels: pixels,
                            sourceUTI: uti,
                            orientation: orientation,
                            iccProfile: sourceICC,
                            metadataPlist: plist,
                            exifAPP1: preserveColorSpace ? ExifSegment.app1(from: url, properties: props) : nil,
                            isRAW: isRAW)
    }

    /// Decodes bytes that never came from a file - the pasteboard, mainly. ImageIO sniffs the
    /// container, so the temporary file needs no meaningful extension.
    public static func decode(data: Data, preserveColorSpace: Bool) throws -> DecodedImage {
        let workspace = try TempWorkspace(label: "squish-decode")
        let url = try workspace.write(data, name: "input", ext: "bin")
        return try decode(url: url, preserveColorSpace: preserveColorSpace)
    }

    // MARK: - Full size decode

    private static func makeFullSizeImage(source: CGImageSource,
                                          properties: [String: Any],
                                          isRAW: Bool,
                                          url: URL) throws -> CGImage? {
        if !isRAW, let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary) {
            return image
        }

        // Camera RAW. ImageIO will demosaic a RAW file only through the thumbnail API with
        // `kCGImageSourceCreateThumbnailFromImageAlways`; CreateImageAtIndex hands back the
        // embedded JPEG preview (or nothing) for several RAW flavours. Asking for a max pixel
        // size equal to the real long edge gets the full demosaiced frame with no resampling.
        // `WithTransform` is deliberately off: orientation is applied by `rasterise` for every
        // format, so the RAW path must not bake it in twice.
        let w = (properties[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let h = (properties[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        let maxEdge = max(w, h)
        var rawOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if maxEdge > 0 { rawOptions[kCGImageSourceThumbnailMaxPixelSize] = maxEdge }
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, rawOptions as CFDictionary) {
            return image
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func isRawUTI(_ uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        guard let raw = UTType("public.camera-raw-image") else { return false }
        return type.conforms(to: raw)
    }

    // MARK: - Orientation

    /// Maps an EXIF orientation to the output size and the CTM that turns the stored pixels
    /// into the displayed image. The context has a bottom-left origin and the image is drawn
    /// into `CGRect(0, 0, w, h)`; `CGAffineTransform` chaining applies the *last* written
    /// operation first, so each expression reads right-to-left.
    static func transform(for orientation: UInt32, width w: Int, height h: Int)
        -> (outWidth: Int, outHeight: Int, ctm: CGAffineTransform) {
        let fw = CGFloat(w), fh = CGFloat(h)
        switch orientation {
        case 2: // mirror horizontal
            return (w, h, CGAffineTransform(translationX: fw, y: 0).scaledBy(x: -1, y: 1))
        case 3: // rotate 180
            return (w, h, CGAffineTransform(translationX: fw, y: fh).rotated(by: .pi))
        case 4: // mirror vertical
            return (w, h, CGAffineTransform(translationX: 0, y: fh).scaledBy(x: 1, y: -1))
        case 5: // mirror horizontal then rotate 270 CW
            return (h, w, CGAffineTransform(translationX: fh, y: 0)
                .rotated(by: .pi / 2)
                .translatedBy(x: fw, y: 0)
                .scaledBy(x: -1, y: 1))
        case 6: // rotate 90 CW
            return (h, w, CGAffineTransform(translationX: 0, y: fw).rotated(by: -.pi / 2))
        case 7: // mirror horizontal then rotate 90 CW
            return (h, w, CGAffineTransform(translationX: 0, y: fw)
                .rotated(by: -.pi / 2)
                .translatedBy(x: fw, y: 0)
                .scaledBy(x: -1, y: 1))
        case 8: // rotate 270 CW
            return (h, w, CGAffineTransform(translationX: fh, y: 0).rotated(by: .pi / 2))
        default:
            return (w, h, .identity)
        }
    }

    private static func rasterise(_ image: CGImage,
                                  orientation: UInt32,
                                  colorSpace: CGColorSpace,
                                  iccProfile: Data?) throws -> PixelImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw SquishError.io("image has zero size") }
        let (outW, outH, ctm) = transform(for: orientation, width: w, height: h)

        let bytesPerRow = outW * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * outH)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: outW,
                                      height: outH,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .high
            ctx.concatenate(ctm)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw SquishError.io("could not create a drawing context for the image") }

        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)

        return PixelImage(width: outW, height: outH, rgba: buffer,
                          hasAlpha: hasAlpha, iccProfile: iccProfile)
    }

    /// Property-list serialisation rejects CFNull and a few CF types ImageIO can hand back.
    private static func sanitise(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                out[key] = sanitise(nested)
            } else if value is String || value is NSNumber || value is Data || value is Date {
                out[key] = value
            } else if let array = value as? [Any] {
                out[key] = array.filter { $0 is String || $0 is NSNumber || $0 is Data || $0 is Date }
            }
        }
        return out
    }
}
