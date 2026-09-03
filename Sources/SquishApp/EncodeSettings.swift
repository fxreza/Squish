import Foundation

/// The three CLI modes, mirrored here so the app and prefs UI can reason about them
/// without depending on SquishCore (the app only ever shells out to the `squish` binary).
///
/// The CLI mode formerly called `web` is now `jpeg`. `cliArgument` goes through
/// `CLICapabilities` so a Squish.app built against an older CLI still works.
enum SquishMode: String, CaseIterable, Sendable {
    case jpeg
    case webp
    case vlossless

    /// Token to pass as the CLI's first positional argument.
    var cliArgument: String {
        switch self {
        case .jpeg: return CLICapabilities.shared.jpegModeToken
        case .webp: return "webp"
        case .vlossless: return "vlossless"
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .vlossless: return "Visually Lossless"
        }
    }

    /// Compact label for the footer.
    var shortName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .vlossless: return "Lossless"
        }
    }

    /// `vlossless` searches for a quality that hits a perceptual target, so a
    /// quality slider is meaningless for it - the window shows a target slider instead.
    var usesQuality: Bool { self != .vlossless }

    /// Tolerates the old `web` spelling stored in UserDefaults by earlier builds.
    static func parse(_ raw: String?) -> SquishMode? {
        guard let raw else { return nil }
        if raw == "web" { return .jpeg }
        return SquishMode(rawValue: raw)
    }
}

/// Everything that changes the *bytes* a compression produces.
///
/// This is the preview cache key's payload: two runs with equal `EncodeSettings`
/// on the same file contents are guaranteed to produce identical output, so a hit
/// can be reused verbatim. Output *placement* (suffix, folder, in-place) is
/// deliberately excluded - it moves the file, it doesn't change it.
struct EncodeSettings: Hashable, Sendable {
    var mode: SquishMode
    /// 1-100, used by `jpeg` and `webp`.
    var quality: Int
    /// Perceptual metric target, used by `vlossless`.
    var target: Int
    var keepMetadata: Bool
    /// nil means "don't downscale".
    var maxDimension: Int?

    /// Zeroes the fields the current mode ignores, so flipping to WebP, moving the
    /// vlossless target, and flipping back still hits the JPEG cache entries.
    var normalized: EncodeSettings {
        var copy = self
        if mode.usesQuality {
            copy.target = 0
        } else {
            copy.quality = 0
        }
        return copy
    }

    /// CLI flags that describe the encode itself. Placement flags are added separately.
    var encodeArguments: [String] {
        var args: [String] = []
        switch mode {
        case .jpeg, .webp:
            args += ["-q", String(quality)]
        case .vlossless:
            args += ["-t", String(target)]
        }
        if keepMetadata {
            args += ["--keep-metadata"]
        }
        if let maxDimension, maxDimension > 0 {
            args += ["--max-dimension", String(maxDimension)]
        }
        return args
    }
}

/// Identity of a source file *as it is right now*. If the user edits a file
/// underneath us its size or mtime moves and every cached preview for it misses.
struct FileFingerprint: Hashable, Sendable {
    var path: String
    var size: Int64
    /// mtime in whole milliseconds - plenty of resolution, and avoids Double hashing.
    var modifiedMillis: Int64

    init(path: String, size: Int64, modifiedMillis: Int64) {
        self.path = path
        self.size = size
        self.modifiedMillis = modifiedMillis
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        self.init(path: url.path,
                  size: Int64(size),
                  modifiedMillis: Int64((modified.timeIntervalSince1970 * 1000).rounded()))
    }
}

/// (file contents, encode settings) - the full preview cache key.
struct PreviewKey: Hashable, Sendable {
    var file: FileFingerprint
    var settings: EncodeSettings
}

/// A completed preview: a real compressed file sitting in the scratch area,
/// ready to be copied into its destination without recompressing.
struct PreviewValue: Sendable {
    var temporaryURL: URL
    var bytesOut: Int64
    var quality: Int?
    var score: Double?
    var belowTarget: Bool

    /// Extension the CLI chose (jpg / webp / png / …). The destination has to match it.
    var pathExtension: String { temporaryURL.pathExtension }
}
