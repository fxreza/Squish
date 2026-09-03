import Foundation
import UniformTypeIdentifiers

public enum ProgressEvent: Sendable {
    case started(index: Int, total: Int, url: URL)
    case finished(index: Int, total: Int, outcome: FileOutcome)
}

/// The bytes a mode produced, plus everything the JSON line needs.
public struct CompressionResult: Sendable {
    public let data: Data
    public let fileExtension: String
    public let quality: Int
    public let score: Double?
    public let belowTarget: Bool?
    public let chroma: String?
}

/// Wires decode -> resize -> heuristic -> encode -> write together, for one file or many.
public struct Pipeline: Sendable {
    let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    // MARK: - Input resolution

    /// Expands the command line into a de-duplicated list of decodable files, in the order the
    /// user gave them. Directories are walked shallowly unless `--recursive`.
    public func resolveInputs(_ options: SquishOptions) throws -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func append(_ url: URL) {
            let std = url.standardizedFileURL
            guard seen.insert(std.path).inserted else { return }
            out.append(std)
        }

        for raw in options.inputs {
            let url = raw.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw SquishError.io("no such file or directory: \(url.path)")
            }
            if !isDir.boolValue {
                // An explicitly named file is taken at face value.
                append(url)
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: opts) else {
                continue
            }
            for case let child as URL in walker {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if !options.recursive && child.deletingLastPathComponent().standardizedFileURL != url {
                        continue
                    }
                    if !options.recursive { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard ImageDecoder.isDecodable(child) else { continue }
                // Do not re-squish our own output on a repeat run over the same folder.
                let stem = child.deletingPathExtension().lastPathComponent
                if !options.suffix.isEmpty && stem.hasSuffix(options.suffix) { continue }
                append(child)
            }
        }
        return out
    }

    // MARK: - Batch

    /// Processes every file with a bounded task group. Concurrency is the core count, halved
    /// for `vlossless` because each file already fans out its own probe encodes.
    public func run(options: SquishOptions,
                    progress: @escaping @Sendable (ProgressEvent) -> Void) async throws -> [FileOutcome] {
        let files = try resolveInputs(options)
        guard !files.isEmpty else { throw SquishError.noInputs }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let limit = max(1, min(options.mode == .vlossless ? max(2, cores / 3) : cores, files.count))

        let results = Locked([Int: FileOutcome]())
        let total = files.count
        // Two inputs that differ only by extension (photo.jpg and photo.tif) would produce the
        // same output stem and one would silently overwrite the other, so the later ones are
        // failed up front rather than processed. Computed before any work starts, so no shared
        // mutable state is involved.
        let blocked = Self.collidingIndices(in: files, options: options)

        let work: @Sendable (Int) async -> Void = { index in
            let url = files[index]
            progress(.started(index: index, total: total, url: url))
            if let winner = blocked[index] {
                let outcome = FileOutcome(
                    input: url.path,
                    bytesIn: (try? url.fileSize()) ?? 0,
                    mode: options.mode.rawValue,
                    ok: false,
                    error: "would overwrite the output of \(winner.lastPathComponent); "
                        + "rename the inputs or run them separately")
                results.withLock { $0[index] = outcome }
                progress(.finished(index: index, total: total, outcome: outcome))
                return
            }
            let outcome = await self.processSafely(url: url, options: options)
            results.withLock { $0[index] = outcome }
            progress(.finished(index: index, total: total, outcome: outcome))
        }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < limit {
                let index = next
                next += 1
                group.addTask { await work(index) }
            }
            while await group.next() != nil {
                guard next < files.count else { continue }
                let index = next
                next += 1
                group.addTask { await work(index) }
            }
        }

        let map = results.wrapped
        return (0..<files.count).compactMap { map[$0] }
    }

    /// Maps an input index to the earlier input it would collide with, if any. Extension is
    /// ignored because the mode decides it.
    static func collidingIndices(in files: [URL], options: SquishOptions) -> [Int: URL] {
        var firstUse: [String: URL] = [:]
        var blocked: [Int: URL] = [:]
        for (index, url) in files.enumerated() {
            let directory = (options.outDir ?? url.deletingLastPathComponent()).standardizedFileURL
            let stem = url.deletingPathExtension().lastPathComponent
                + (options.inplace ? "" : options.suffix)
            let key = directory.appendingPathComponent(stem).path
            if let existing = firstUse[key] {
                blocked[index] = existing
            } else {
                firstUse[key] = url
            }
        }
        return blocked
    }

    func processSafely(url: URL, options: SquishOptions) async -> FileOutcome {
        do {
            return try await process(url: url, options: options)
        } catch {
            let message = (error as? SquishError)?.description ?? error.localizedDescription
            return FileOutcome(input: url.path,
                               bytesIn: (try? url.fileSize()) ?? 0,
                               mode: options.mode.rawValue,
                               ok: false,
                               error: message)
        }
    }

    // MARK: - Single file

    public func process(url: URL, options: SquishOptions) async throws -> FileOutcome {
        let bytesIn = try url.fileSize()
        let decoded = try ImageDecoder.decode(url: url, preserveColorSpace: options.keepMetadata)
        let originalBytes: Data? = options.maxDimension == nil
            ? try? Data(contentsOf: url, options: .mappedIfSafe)
            : nil

        let result = try await compress(decoded: decoded,
                                        originalFileBytes: originalBytes,
                                        options: options)

        let destination = try OutputPlanner.destination(for: url,
                                                        fileExtension: result.fileExtension,
                                                        options: options)
        try OutputPlanner.write(result.data, to: destination, replacing: url, options: options)

        return FileOutcome(input: url.path,
                           output: destination.path,
                           bytesIn: bytesIn,
                           bytesOut: result.data.count,
                           quality: result.quality,
                           score: result.score,
                           mode: options.mode.rawValue,
                           ok: true,
                           error: nil,
                           belowTarget: result.belowTarget,
                           chroma: result.chroma)
    }

    // MARK: - The three modes

    /// Runs the selected mode against an already-decoded image. Shared by the file pipeline and
    /// by `--clipboard`, which has no file to read or write.
    public func compress(decoded: DecodedImage,
                         originalFileBytes: Data?,
                         options: SquishOptions) async throws -> CompressionResult {
        let workspace = try TempWorkspace()
        var pixels = decoded.pixels
        if let maxDimension = options.maxDimension {
            pixels = try Resampler.fit(pixels, maxLongEdge: maxDimension)
        }
        let analysis = ContentAnalyzer.analyze(pixels)
        let settings = EncodeSettings(quality: options.effectiveQuality,
                                      chroma: analysis.chroma,
                                      keepMetadata: options.keepMetadata,
                                      iccProfile: decoded.iccProfile,
                                      exifAPP1: decoded.exifAPP1,
                                      metadataPlist: decoded.metadataPlist)

        switch options.mode {
        case .jpeg:
            let encoder = MozjpegEncoder(resolver: resolver)
            let data = try encoder.encode(pixels, settings: settings, workspace: workspace)
            let score = verificationScore(of: data, ext: "jpg", pixels: pixels.flattenedOverWhite(),
                                          workspace: workspace, enabled: options.verify)
            return CompressionResult(data: data,
                                     fileExtension: "jpg",
                                     quality: settings.quality,
                                     score: score,
                                     belowTarget: nil,
                                     chroma: analysis.chroma.rawValue)

        case .webp:
            let encoder = WebPEncoder(resolver: resolver)
            let data = try encoder.encode(pixels, settings: settings, workspace: workspace)
            let score = verificationScore(of: data, ext: "webp", pixels: pixels,
                                          workspace: workspace, enabled: options.verify)
            return CompressionResult(data: data,
                                     fileExtension: "webp",
                                     quality: settings.quality,
                                     score: score,
                                     belowTarget: nil,
                                     chroma: analysis.chroma.rawValue)

        case .vlossless:
            return try await visuallyLossless(pixels: pixels,
                                              decoded: decoded,
                                              originalFileBytes: originalFileBytes,
                                              settings: settings,
                                              analysis: analysis,
                                              options: options,
                                              workspace: workspace)
        }
    }

    /// `vlossless` keeps the input format where an encoder exists for it.
    ///
    /// DEVIATION FROM THE SPEC, documented: the spec says vlossless "keeps input format", but
    /// the bundled codecs can only write JPEG, PNG and WebP. A TIFF/HEIC/PSD/RAW input therefore
    /// comes out as PNG when it carries alpha or reads as graphics, and JPEG otherwise. JPEG in
    /// stays JPEG out and PNG in stays PNG out, which is what the spec's own examples call out.
    private enum Family {
        case jpeg, png

        /// True when re-emitting the input file verbatim would produce a coherent output of
        /// this family.
        func matchesContainer(of uti: String?) -> Bool {
            switch self {
            case .jpeg: return uti == UTType.jpeg.identifier
            case .png: return uti == UTType.png.identifier
            }
        }
    }

    private func family(for decoded: DecodedImage, analysis: ContentAnalysis, pixels: PixelImage) -> Family {
        switch decoded.sourceUTI {
        case UTType.jpeg.identifier: return .jpeg
        case UTType.png.identifier: return .png
        default:
            // Alpha forces PNG. Otherwise PNG is only worth it for genuinely palette-like
            // graphics: a smooth grainy render classifies as graphics for chroma purposes but
            // would balloon as a PNG, so the colour count is the tiebreak.
            if pixels.hasAlpha { return .png }
            return (analysis.isGraphics && analysis.uniqueColors < 4096) ? .png : .jpeg
        }
    }

    private func visuallyLossless(pixels: PixelImage,
                                  decoded: DecodedImage,
                                  originalFileBytes: Data?,
                                  settings: EncodeSettings,
                                  analysis: ContentAnalysis,
                                  options: SquishOptions,
                                  workspace: TempWorkspace) async throws -> CompressionResult {
        let kind = family(for: decoded, analysis: analysis, pixels: pixels)
        let ext = kind == .jpeg ? "jpg" : "png"
        // JPEG has no alpha, so the reference the metric sees must be flattened the same way.
        let reference = kind == .jpeg ? pixels.flattenedOverWhite() : pixels
        guard let scorer = try scorer(for: reference, workspace: workspace) else {
            throw SquishError.metricUnavailable
        }

        // The always-valid, always-100 candidate: a lossless repack of the source.
        var losslessCandidate: (data: Data, quality: Int)?
        switch kind {
        case .jpeg:
            let jpegtran = JpegtranOptimizer(resolver: resolver)
            // Only when the stored pixels already display correctly: a rotated source would
            // come back with the wrong geometry, because jpegtran cannot see the reference the
            // metric compared against (which has the orientation applied).
            if let bytes = originalFileBytes,
               decoded.sourceUTI == UTType.jpeg.identifier,
               decoded.orientation == 1,
               jpegtran.isAvailable,
               let repacked = try? jpegtran.optimize(bytes, keepMetadata: options.keepMetadata) {
                losslessCandidate = (repacked, 100)
            }
        case .png:
            let png = PngEncoder(resolver: resolver)
            if let data = try? png.encodeLossless(pixels, settings: settings) {
                losslessCandidate = (data, 100)
            }
        }

        let jpegEncoder = MozjpegEncoder(resolver: resolver)
        let pngEncoder = PngEncoder(resolver: resolver)
        let baseSettings = settings

        let search = try await QualitySearch.run(
            target: options.target,
            encode: { quality in
                var s = baseSettings
                s.quality = quality
                switch kind {
                case .jpeg: return try jpegEncoder.encode(pixels, settings: s, workspace: workspace)
                case .png: return try pngEncoder.encode(pixels, settings: s, workspace: workspace)
                }
            },
            measure: { _, data in
                try scorer.score(data, ext: ext)
            })

        // Smallest passing file wins, and the lossless repack is just another candidate.
        var bestData = search.data
        var bestQuality = search.quality
        var bestScore = search.score
        var belowTarget = search.belowTarget

        if let lossless = losslessCandidate,
           belowTarget || lossless.data.count < bestData.count {
            // A lossless repack is pixel-identical, so it always meets the target. Take it when
            // it is smaller, and take it regardless when the search never reached the target.
            bestData = lossless.data
            bestQuality = lossless.quality
            bestScore = 100
            belowTarget = false
        }

        // Last line of defence: vlossless must never hand back a file bigger than the one it was
        // given. That is reachable when the input is already compressed harder than the search
        // can match and no lossless repack is available - a rotated JPEG, for instance, where the
        // repack candidate is disabled because jpegtran cannot reproduce the reference geometry.
        // The original bytes are by definition at the target, so they are the honest answer.
        // Only valid when nothing about the pixels changed: no downscale (which is what makes
        // `originalFileBytes` nil) and the same container going out as came in.
        if let original = originalFileBytes,
           original.count < bestData.count,
           kind.matchesContainer(of: decoded.sourceUTI) {
            bestData = original
            bestQuality = 100
            bestScore = 100
            belowTarget = false
        }

        return CompressionResult(data: bestData,
                                 fileExtension: ext,
                                 quality: bestQuality,
                                 score: bestScore,
                                 belowTarget: belowTarget,
                                 chroma: kind == .jpeg ? analysis.chroma.rawValue : nil)
    }

    // MARK: - Scoring

    /// Writes the reference PNG once per file and hands back something that can score any number
    /// of candidates against it. Returns nil when no metric binary is installed.
    /// Best-effort score for `jpeg`/`webp`, so the JSON line carries one. Never fatal: a missing
    /// or unhappy metric binary must not fail an otherwise successful compression.
    private func verificationScore(of data: Data,
                                   ext: String,
                                   pixels: PixelImage,
                                   workspace: TempWorkspace,
                                   enabled: Bool) -> Double? {
        guard enabled else { return nil }
        guard let candidateScorer = try? scorer(for: pixels, workspace: workspace) else { return nil }
        return try? candidateScorer.score(data, ext: ext)
    }

    private func scorer(for pixels: PixelImage, workspace: TempWorkspace) throws -> CandidateScorer? {
        guard let metric = MetricFactory.resolve(resolver) else { return nil }
        let reference = workspace.path("reference", ext: "png")
        try pixels.write(png: reference)
        return CandidateScorer(metric: metric, reference: reference, workspace: workspace)
    }
}

struct CandidateScorer: Sendable {
    let metric: PerceptualMetric
    let reference: URL
    let workspace: TempWorkspace

    func score(_ data: Data, ext: String) throws -> Double {
        let url: URL
        if ext == "jpg" || ext == "jpeg" || ext == "png" {
            url = try workspace.write(data, name: "candidate", ext: ext)
        } else {
            url = try workspace.write(try ImageTranscoder.toPNG(data), name: "candidate", ext: "png")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try metric.score(original: reference, candidate: url)
    }
}

extension URL {
    func fileSize() throws -> Int {
        let values = try resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}
