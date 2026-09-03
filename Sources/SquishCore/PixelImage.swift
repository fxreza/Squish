import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A decoded image in one canonical layout: 8-bit RGBA, premultiplied, alpha last, tightly
/// packed. Everything downstream (encoders, heuristic, resampler) speaks this and nothing else.
///
/// Deliberately a value type holding `[UInt8]`, not a `CGImage`, so it is `Sendable` and can be
/// handed to concurrent encode tasks. It is also the decode cache: `vlossless` decodes once and
/// re-encodes this buffer six times.
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    /// Premultiplied RGBA, `width * height * 4` bytes, no row padding.
    public let rgba: [UInt8]
    /// True when the source actually carried an alpha channel.
    public let hasAlpha: Bool
    /// ICC profile the samples are expressed in. `nil` means sRGB.
    public let iccProfile: Data?

    public var bytesPerRow: Int { width * 4 }
    public var pixelCount: Int { width * height }
    public var longEdge: Int { max(width, height) }

    public init(width: Int, height: Int, rgba: [UInt8], hasAlpha: Bool, iccProfile: Data?) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.hasAlpha = hasAlpha
        self.iccProfile = iccProfile
    }

    func colorSpace() -> CGColorSpace {
        if let icc = iccProfile,
           let cs = CGColorSpace(iccData: icc as CFData),
           cs.model == .rgb {
            return cs
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Rebuilds a CGImage. Only needed on the ImageIO write paths (temp PNG, clipboard).
    ///
    /// The buffer is always 32-bit RGBA, but when the image carries no alpha the fourth channel
    /// is declared `noneSkipLast` so ImageIO writes a 24-bit RGB PNG. This matters more than it
    /// looks: an RGBA reference PNG makes ssimulacra2 score roughly 1.4 points lower than the
    /// identical RGB one (measured: 89.56 vs 90.95 on the same candidate), which quietly
    /// depressed every reported score and pushed the vlossless search a whole quality step
    /// higher than it needed to go.
    public func makeCGImage() throws -> CGImage {
        let alpha = hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let info = CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            throw SquishError.io("could not wrap pixel buffer")
        }
        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace(),
                                  bitmapInfo: info,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw SquishError.io("could not rebuild CGImage from pixel buffer")
        }
        return image
    }

    /// Composites over white and drops alpha. JPEG cannot carry alpha, so this is what the
    /// encoder effectively sees - and therefore what the perceptual metric has to be shown as
    /// the reference, otherwise every transparent pixel reads as a huge error.
    public func flattenedOverWhite() -> PixelImage {
        guard hasAlpha else { return self }
        var out = rgba
        out.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: p.count, by: 4) {
                let fill = 255 &- p[i + 3]
                p[i] = p[i] &+ fill
                p[i + 1] = p[i + 1] &+ fill
                p[i + 2] = p[i + 2] &+ fill
                p[i + 3] = 255
            }
        }
        return PixelImage(width: width, height: height, rgba: out,
                          hasAlpha: false, iccProfile: iccProfile)
    }

    // MARK: - Serialisation for the helper binaries

    /// Binary PPM (P6). What mozjpeg's cjpeg eats on stdin. JPEG has no alpha, so a
    /// premultiplied pixel is composited over white, which for premultiplied samples is just
    /// `c + (255 - a)`.
    public func ppmData() -> Data {
        let header = Array("P6\n\(width) \(height)\n255\n".utf8)
        var out = [UInt8](repeating: 0, count: header.count + pixelCount * 3)
        out.replaceSubrange(0..<header.count, with: header)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = 0
                var d = header.count
                if hasAlpha {
                    for _ in 0..<pixelCount {
                        let a = src[s + 3]
                        let fill = 255 &- a
                        dst[d] = src[s] &+ fill
                        dst[d + 1] = src[s + 1] &+ fill
                        dst[d + 2] = src[s + 2] &+ fill
                        s += 4; d += 3
                    }
                } else {
                    for _ in 0..<pixelCount {
                        dst[d] = src[s]
                        dst[d + 1] = src[s + 1]
                        dst[d + 2] = src[s + 2]
                        s += 4; d += 3
                    }
                }
            }
        }
        return Data(out)
    }

    /// PNG via ImageIO. Used as cwebp/pngquant input and as the perceptual metric reference.
    /// The ICC profile rides along automatically because the CGImage carries the colour space;
    /// `properties` (EXIF/TIFF/GPS dictionaries) is only passed when --keep-metadata is on, so
    /// `cwebp -metadata all` and pngquant/oxipng can carry them through.
    public func pngData(properties: [String: Any]? = nil) throws -> Data {
        let image = try makeCGImage()
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw SquishError.io("could not create PNG destination")
        }
        var opts: [CFString: Any] = [:]
        if let props = properties {
            for (key, value) in props { opts[key as CFString] = value }
        }
        CGImageDestinationAddImage(dest, image, opts.isEmpty ? nil : opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SquishError.io("could not encode intermediate PNG")
        }
        return out as Data
    }

    public func write(png url: URL, properties: [String: Any]? = nil) throws {
        let data = try pngData(properties: properties)
        do { try data.write(to: url, options: .atomic) }
        catch { throw SquishError.io("could not write \(url.path): \(error.localizedDescription)") }
    }
}
