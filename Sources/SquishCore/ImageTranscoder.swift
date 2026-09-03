import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageTranscoder {
    /// Re-wraps arbitrary encoded image bytes as PNG. Needed because the perceptual metrics
    /// read PNG/JPEG but not necessarily WebP, and `jpeg`/`webp` verification has to hand the
    /// metric something it can open.
    static func toPNG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SquishError.io("could not re-read encoded image for scoring")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw SquishError.io("could not create PNG destination for scoring")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SquishError.io("could not transcode encoded image for scoring")
        }
        return out as Data
    }
}
