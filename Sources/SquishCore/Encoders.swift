import Foundation

/// Everything an encoder needs beyond the pixels.
public struct EncodeSettings: Sendable {
    public var quality: Int
    public var chroma: Chroma
    public var keepMetadata: Bool
    public var iccProfile: Data?
    /// Prebuilt JPEG APP1/Exif segment (see `ExifSegment`).
    public var exifAPP1: Data?
    /// Source image properties as a binary plist, re-inflated locally by the PNG/WebP paths.
    public var metadataPlist: Data?
    /// cwebp `-m`: compression effort, 0 fastest ... 6 smallest.
    public var webpEffort: Int

    public init(quality: Int,
                chroma: Chroma = .fourTwoZero,
                keepMetadata: Bool = false,
                iccProfile: Data? = nil,
                exifAPP1: Data? = nil,
                metadataPlist: Data? = nil,
                webpEffort: Int = 6) {
        self.quality = quality
        self.chroma = chroma
        self.keepMetadata = keepMetadata
        self.iccProfile = iccProfile
        self.exifAPP1 = exifAPP1
        self.metadataPlist = metadataPlist
        self.webpEffort = webpEffort
    }

    func metadataProperties() -> [String: Any]? {
        guard keepMetadata, let data = metadataPlist else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

public protocol ImageEncoder: Sendable {
    var toolName: String { get }
    var fileExtension: String { get }
    func encode(_ image: PixelImage, settings: EncodeSettings, workspace: TempWorkspace) throws -> Data
}

// MARK: - mozjpeg

/// Drives `cjpeg`. Pixels go in as binary PPM on stdin, JPEG comes back on stdout, so the only
/// file that ever touches the disk is the optional ICC profile for `-icc`.
public struct MozjpegEncoder: ImageEncoder {
    public let toolName = "cjpeg"
    public let fileExtension = "jpg"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public func encode(_ image: PixelImage, settings: EncodeSettings, workspace: TempWorkspace) throws -> Data {
        let exe = try resolver.url(for: toolName)
        var args = [
            "-quality", String(settings.quality),
            "-optimize",
            "-progressive",
            "-sample", settings.chroma.cjpegSample,
        ]
        if settings.keepMetadata, let icc = settings.iccProfile, !icc.isEmpty {
            let iccURL = try ExifSegment.writeICC(icc, workspace: workspace)
            args += ["-icc", iccURL.path]
        }
        let result = try ProcessRunner.runChecked(executable: exe,
                                                  arguments: args,
                                                  stdin: image.ppmData(),
                                                  toolName: toolName)
        guard !result.stdout.isEmpty else {
            throw SquishError.toolFailed(tool: toolName, status: 0, message: "produced no output")
        }
        if settings.keepMetadata, let app1 = settings.exifAPP1 {
            return ExifSegment.splice(app1, into: result.stdout)
        }
        return result.stdout
    }
}

// MARK: - jpegtran

/// Lossless repack of an existing JPEG: re-optimises the Huffman tables and rewrites it as
/// progressive without touching a single DCT coefficient. In `vlossless` this is the free
/// candidate that always scores 100, and it is often the winner on already-tuned JPEGs.
public struct JpegtranOptimizer: Sendable {
    public let toolName = "jpegtran"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public var isAvailable: Bool { resolver.exists(toolName) }

    public func optimize(_ jpeg: Data, keepMetadata: Bool) throws -> Data {
        let exe = try resolver.url(for: toolName)
        let args = ["-optimize", "-progressive", "-copy", keepMetadata ? "all" : "none"]
        let result = try ProcessRunner.runChecked(executable: exe,
                                                  arguments: args,
                                                  stdin: jpeg,
                                                  toolName: toolName)
        return result.stdout.isEmpty ? jpeg : result.stdout
    }
}

// MARK: - WebP

/// Drives `cwebp`. cwebp will not read pixels from stdin, so the frame is handed over as a
/// temporary PNG - which also gives us a free ride for the ICC profile and EXIF under
/// `--keep-metadata`, since ImageIO writes both into the PNG and `-metadata all` copies them.
public struct WebPEncoder: ImageEncoder {
    public let toolName = "cwebp"
    public let fileExtension = "webp"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public func encode(_ image: PixelImage, settings: EncodeSettings, workspace: TempWorkspace) throws -> Data {
        let exe = try resolver.url(for: toolName)
        let input = workspace.path("cwebp-in", ext: "png")
        try image.write(png: input, properties: settings.metadataProperties())
        let output = workspace.path("cwebp-out", ext: "webp")

        var args = [
            "-q", String(settings.quality),
            "-m", String(settings.webpEffort),
            "-mt",
            "-alpha_q", "100",
            "-metadata", settings.keepMetadata ? "all" : "none",
            "-quiet",
        ]
        // -sharp_yuv costs encode time but keeps chroma edges crisp, which is the WebP analogue
        // of picking 4:4:4 for a screenshot.
        if settings.chroma == .fourFourFour { args.append("-sharp_yuv") }
        args += ["-o", output.path, input.path]

        try ProcessRunner.runChecked(executable: exe, arguments: args, toolName: toolName)
        guard let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw SquishError.toolFailed(tool: toolName, status: 0, message: "produced no output")
        }
        return data
    }
}

// MARK: - PNG

/// Drives `pngquant`: lossy palette quantisation. Quality is expressed as `0-N` so pngquant
/// never refuses the job; the perceptual metric, not pngquant, decides whether N was good
/// enough.
public struct PngQuantEncoder: Sendable {
    public let toolName = "pngquant"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public var isAvailable: Bool { resolver.exists(toolName) }

    public func quantize(_ png: Data, quality: Int, keepMetadata: Bool) throws -> Data {
        let exe = try resolver.url(for: toolName)
        var args = ["--quality=0-\(max(0, min(100, quality)))", "--speed", "1", "--force"]
        if !keepMetadata { args.append("--strip") }
        args.append("-")
        let result = try ProcessRunner.run(executable: exe, arguments: args, stdin: png, toolName: toolName)
        // 98/99 mean "could not reach the requested quality"; with a 0 floor that should not
        // happen, but if it does the caller gets the unquantised PNG and oxipng still runs.
        guard result.status == 0, !result.stdout.isEmpty else { return png }
        return result.stdout
    }
}

/// Drives `oxipng`: lossless PNG recompression. Always safe to run, so it terminates every PNG
/// path whether or not quantisation happened.
public struct OxipngOptimizer: Sendable {
    public let toolName = "oxipng"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public var isAvailable: Bool { resolver.exists(toolName) }

    public func optimize(_ png: Data, level: Int = 4, keepMetadata: Bool) throws -> Data {
        let exe = try resolver.url(for: toolName)
        let args = ["-o", String(level),
                    "--strip", keepMetadata ? "none" : "safe",
                    "--quiet", "--stdout", "-"]
        let result = try ProcessRunner.run(executable: exe, arguments: args, stdin: png, toolName: toolName)
        guard result.status == 0, !result.stdout.isEmpty else { return png }
        return result.stdout.count < png.count ? result.stdout : png
    }
}

/// pngquant + oxipng as one encoder, so the quality search can treat PNG like any other codec.
public struct PngEncoder: ImageEncoder {
    public let toolName = "pngquant"
    public let fileExtension = "png"
    private let quant: PngQuantEncoder
    private let oxi: OxipngOptimizer

    public init(resolver: BinaryResolver = .shared) {
        self.quant = PngQuantEncoder(resolver: resolver)
        self.oxi = OxipngOptimizer(resolver: resolver)
    }

    public func encode(_ image: PixelImage, settings: EncodeSettings, workspace: TempWorkspace) throws -> Data {
        let base = try image.pngData(properties: settings.metadataProperties())
        var data = base
        if quant.isAvailable {
            data = try quant.quantize(base, quality: settings.quality, keepMetadata: settings.keepMetadata)
        }
        if oxi.isAvailable {
            data = try oxi.optimize(data, keepMetadata: settings.keepMetadata)
        }
        return data
    }

    /// Lossless-only variant: the `score == 100` candidate for the vlossless PNG path.
    public func encodeLossless(_ image: PixelImage, settings: EncodeSettings) throws -> Data {
        let base = try image.pngData(properties: settings.metadataProperties())
        guard oxi.isAvailable else { return base }
        return try oxi.optimize(base, keepMetadata: settings.keepMetadata)
    }
}
