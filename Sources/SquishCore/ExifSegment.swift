import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// JPEG APP-segment surgery for `--keep-metadata`.
///
/// mozjpeg's `cjpeg` takes raw PPM on stdin, so there is no way to hand it an EXIF dictionary
/// (`-icc` covers the colour profile, nothing covers EXIF). The fix is to build a well-formed
/// `APP1`/Exif segment and splice it into the JPEG mozjpeg produced. That is a defined,
/// order-insensitive operation: readers look for `APP1` anywhere in the header.
public enum ExifSegment {

    /// Produces an `APP1` Exif segment (marker + length + payload) for the source image.
    /// Lifted verbatim from the file when the source is itself a JPEG; otherwise synthesised by
    /// having ImageIO write a 1x1 JPEG carrying the source's EXIF/TIFF/GPS dictionaries and
    /// taking the segment back out of it.
    public static func app1(from url: URL, properties: [String: Any]) -> Data? {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let segment = extractAPP1(fromJPEG: data) {
            return normalisingOrientation(in: segment)
        }
        return synthesise(properties: properties)
    }

    /// Rewrites the IFD0 Orientation tag to 1.
    ///
    /// The decoder bakes EXIF orientation into the pixels, so carrying the source's orientation
    /// value through to the output would rotate the image a second time in every viewer. The
    /// tag is edited in place rather than dropped, because removing an IFD entry means rewriting
    /// every offset in the block.
    static func normalisingOrientation(in segment: Data) -> Data {
        var bytes = [UInt8](segment)
        // [FF E1][len:2]["Exif\0\0"] = 10 bytes before the TIFF header.
        let tiff = 10
        guard bytes.count > tiff + 8 else { return segment }
        let bigEndian: Bool
        switch (bytes[tiff], bytes[tiff + 1]) {
        case (0x4D, 0x4D): bigEndian = true   // "MM"
        case (0x49, 0x49): bigEndian = false  // "II"
        default: return segment
        }
        func u16(_ offset: Int) -> Int {
            bigEndian ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                      : Int(bytes[offset + 1]) << 8 | Int(bytes[offset])
        }
        func u32(_ offset: Int) -> Int {
            bigEndian
                ? Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                : Int(bytes[offset + 3]) << 24 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset])
        }
        let ifd0 = tiff + u32(tiff + 4)
        guard ifd0 + 2 <= bytes.count else { return segment }
        let entryCount = u16(ifd0)
        for index in 0..<entryCount {
            let entry = ifd0 + 2 + index * 12
            guard entry + 12 <= bytes.count else { break }
            guard u16(entry) == 0x0112 else { continue } // Orientation
            let value = entry + 8
            if bigEndian {
                bytes[value] = 0; bytes[value + 1] = 1
            } else {
                bytes[value] = 1; bytes[value + 1] = 0
            }
            bytes[value + 2] = 0; bytes[value + 3] = 0
            return Data(bytes)
        }
        return segment
    }

    /// Inserts `segment` into `jpeg` right after the SOI, skipping a leading JFIF APP0 so the
    /// JFIF marker stays first as convention expects.
    public static func splice(_ segment: Data, into jpeg: Data) -> Data {
        guard jpeg.count > 4 else { return jpeg }
        let bytes = [UInt8](jpeg)
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }

        var insertAt = 2
        if bytes.count > 4, bytes[2] == 0xFF, bytes[3] == 0xE0 {
            let length = Int(bytes[4]) << 8 | Int(bytes[5])
            if 4 + length <= bytes.count { insertAt = 4 + length }
        }
        var out = Data(bytes[0..<insertAt])
        out.append(segment)
        out.append(Data(bytes[insertAt...]))
        return out
    }

    /// Wraps an ICC profile so cjpeg can be pointed at it with `-icc`.
    public static func writeICC(_ icc: Data, workspace: TempWorkspace) throws -> URL {
        try workspace.write(icc, name: "profile", ext: "icc")
    }

    // MARK: - JPEG marker walk

    static func extractAPP1(fromJPEG data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }
            // Standalone markers carry no length.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) { i += 2; continue }
            // Stop at the start of scan; nothing after it is a header segment.
            if marker == 0xDA { return nil }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= bytes.count else { return nil }
            if marker == 0xE1 {
                let payloadStart = i + 4
                let payloadEnd = i + 2 + length
                if payloadEnd - payloadStart >= 6 {
                    let tag = Array(bytes[payloadStart..<(payloadStart + 6)])
                    if tag == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] { // "Exif\0\0"
                        return Data(bytes[i..<payloadEnd])
                    }
                }
            }
            i += 2 + length
        }
        return nil
    }

    private static func synthesise(properties: [String: Any]) -> Data? {
        var carried: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary,
                    kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary] {
            if let value = properties[key as String] { carried[key] = value }
        }
        // Orientation is deliberately forced to 1: the pixels already have it applied.
        carried[kCGImagePropertyOrientation] = 1
        if var tiff = carried[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            carried[kCGImagePropertyTIFFDictionary] = tiff
        }
        guard !carried.isEmpty else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 255]
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: space, bitmapInfo: info),
              let tiny = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, tiny, carried as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return extractAPP1(fromJPEG: out as Data)
    }
}
