// The only file in SquishCore that imports AppKit. Everything else stays AppKit-free so the
// core can be linked into non-GUI contexts.
import Foundation
import AppKit
import UniformTypeIdentifiers

/// An image taken off the pasteboard, plus how many bytes it occupied there, so the result line
/// can report a meaningful `bytesIn` instead of the size of the decoded bitmap.
public struct ClipboardImage: Sendable {
    public let image: DecodedImage
    public let sourceByteCount: Int
}

public enum Clipboard {

    /// Pulls an image off the general pasteboard. Prefers a lossless representation, and falls
    /// back to a file promise (what Finder puts there when you copy a file).
    public static func readImage() throws -> ClipboardImage {
        let pasteboard = NSPasteboard.general

        let preferred: [NSPasteboard.PasteboardType] = [
            .init(UTType.png.identifier),
            .init(UTType.tiff.identifier),
            .tiff,
            .init(UTType.jpeg.identifier),
            .init(UTType.heic.identifier),
            .init("com.compuserve.gif"),
        ]
        for type in preferred {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return ClipboardImage(image: try ImageDecoder.decode(data: data, preserveColorSpace: false),
                                      sourceByteCount: data.count)
            }
        }
        // Anything else the pasteboard advertises that ImageIO might understand.
        for type in pasteboard.types ?? [] {
            guard let uti = UTType(type.rawValue), uti.conforms(to: .image) else { continue }
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return ClipboardImage(image: try ImageDecoder.decode(data: data, preserveColorSpace: false),
                                      sourceByteCount: data.count)
            }
        }
        // A copied file.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { ImageDecoder.isDecodable($0) }) {
            return ClipboardImage(image: try ImageDecoder.decode(url: url, preserveColorSpace: false),
                                  sourceByteCount: (try? url.fileSize()) ?? 0)
        }
        throw SquishError.clipboardEmpty
    }

    /// Puts the compressed bytes back. The encoded type is declared first so a paste target that
    /// understands it gets the small file; TIFF is added as a fallback for apps that only accept
    /// bitmap data (nothing reads WebP off a pasteboard).
    public static func writeImage(_ data: Data, fileExtension: String) throws {
        let uti: UTType
        switch fileExtension {
        case "jpg", "jpeg": uti = .jpeg
        case "png": uti = .png
        case "webp": uti = UTType("org.webmproject.webp") ?? .png
        default: uti = .png
        }
        let primary = NSPasteboard.PasteboardType(uti.identifier)

        var types: [NSPasteboard.PasteboardType] = [primary]
        var fallback: Data?
        if uti != .tiff, let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            fallback = tiff
            types.append(.tiff)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        guard pasteboard.setData(data, forType: primary) else {
            throw SquishError.clipboardWriteFailed
        }
        if let fallback { _ = pasteboard.setData(fallback, forType: .tiff) }
    }
}
