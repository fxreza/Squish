import AppKit
import ImageIO

/// One row in the file list.
///
/// A reference type on the main actor: the table, the coordinator and the footer all
/// look at the same instance, so a finished preview updates every surface at once
/// without any copying back and forth.
@MainActor
final class FileItem {

    enum State {
        /// Queued, nothing known yet.
        case pending
        /// An encode is running for the current settings.
        case calculating
        /// Preview complete - a real compressed file exists in the scratch area.
        case ready(PreviewValue)
        /// The CLI refused this file (unsupported, unreadable, …).
        case failed(String)
    }

    let id = UUID()
    let url: URL
    private(set) var originalBytes: Int64
    private(set) var fingerprint: FileFingerprint

    var state: State = .pending

    /// Set once the file has actually been written to its destination, and cleared
    /// whenever the settings change, so "Exported" never lies about stale output.
    var exported: (url: URL, settings: EncodeSettings)?

    /// Why the last export attempt failed. Kept apart from `state` so a failed write
    /// doesn't throw away a perfectly good preview.
    var exportError: String?

    init?(url: URL) {
        let standardized = url.standardizedFileURL
        guard let fingerprint = FileFingerprint(url: standardized) else { return nil }
        self.url = standardized
        self.fingerprint = fingerprint
        self.originalBytes = fingerprint.size
    }

    /// Source pixel dimensions, read from the file's header only (no decode) the first
    /// time something asks. The Resize row needs them to keep the two fields in step
    /// and to say what the output will be; nothing else depends on them.
    private var pixelSizeLoaded = false
    private var cachedPixelSize: (width: Int, height: Int)?

    var pixelSize: (width: Int, height: Int)? {
        if pixelSizeLoaded { return cachedPixelSize }
        pixelSizeLoaded = true
        cachedPixelSize = FileItem.readPixelSize(of: url)
        return cachedPixelSize
    }

    private static func readPixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // A sideways EXIF orientation means the pixels the pipeline sees are the other
        // way round; the decoder applies it, so report what the resize will act on.
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let sideways = [5, 6, 7, 8].contains(orientation)
        return sideways ? (height, width) : (width, height)
    }

    /// Re-stats the file. Returns true if it changed, which means every cached preview
    /// for it is now stale.
    @discardableResult
    func refreshFingerprint() -> Bool {
        guard let fresh = FileFingerprint(url: url), fresh != fingerprint else { return false }
        fingerprint = fresh
        originalBytes = fresh.size
        exported = nil
        pixelSizeLoaded = false
        cachedPixelSize = nil
        return true
    }

    func key(for settings: EncodeSettings) -> PreviewKey {
        PreviewKey(file: fingerprint, settings: settings.normalized)
    }

    // MARK: - Derived display values

    var projectedBytes: Int64? {
        if case .ready(let value) = state { return value.bytesOut }
        return nil
    }

    var savedPercent: Double? {
        guard let projected = projectedBytes, originalBytes > 0 else { return nil }
        return (Double(originalBytes - projected) / Double(originalBytes)) * 100
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .pending, .calculating: return true
        case .ready, .failed: return false
        }
    }

    /// Text for the Status column.
    func statusText(for settings: EncodeSettings) -> String {
        if let exportError { return exportError }
        switch state {
        case .pending:
            return "Waiting"
        case .calculating:
            return settings.mode == .vlossless ? "Searching…" : "Calculating…"
        case .failed(let message):
            return message
        case .ready(let value):
            if let exported, exported.settings == settings.normalized {
                return "Exported"
            }
            if value.belowTarget {
                return "Below target · q\(value.quality ?? 0)"
            }
            if settings.mode == .vlossless, let quality = value.quality {
                return "Ready · q\(quality)"
            }
            return "Ready"
        }
    }

    func isFailed() -> Bool {
        if case .failed = state { return true }
        return false
    }
}
