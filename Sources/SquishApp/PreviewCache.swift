import Foundation

/// LRU cache of *real* compressed files.
///
/// The window never estimates a compressed size: to show a projected size it actually
/// runs the encoder into a scratch directory, so the number on screen is the exact
/// number of bytes the user will get. That is only affordable because of this cache -
/// flipping JPEG -> WebP -> JPEG, or nudging the slider back to a value visited a
/// moment ago, is a dictionary lookup, not an encode.
///
/// The key is `(file fingerprint, encode settings)`, where the fingerprint is
/// path + size + mtime, so editing a file underneath us invalidates it, and the
/// settings are normalised so the mode's irrelevant knob can't cause a false miss.
///
/// Everything lives under one per-process scratch directory that is deleted on quit.
actor PreviewCache {

    static let shared = PreviewCache()

    /// Roughly 40 files x 6 explored settings. Each entry is one compressed image;
    /// even at a generous 2 MB apiece that caps the scratch area at a few hundred MB,
    /// and in practice entries are far smaller than their originals.
    private let limit = 240

    private var entries: [PreviewKey: PreviewValue] = [:]
    /// Least-recently-used first.
    private var usage: [PreviewKey] = []
    private var scratchCounter = 0

    /// `…/TemporaryDirectory/com.fxreza.squish/previews/<pid>-<uuid>`
    private let root: URL

    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.fxreza.squish", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
        root = base.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                          isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PreviewCache.sweepAbandonedScratchDirectories(under: base, keeping: root)
    }

    // MARK: - Lookup

    func value(for key: PreviewKey) -> PreviewValue? {
        guard let value = entries[key] else { return nil }
        // A cached file that vanished (someone emptied /tmp) is a miss, not a crash.
        guard FileManager.default.fileExists(atPath: value.temporaryURL.path) else {
            drop(key)
            return nil
        }
        touch(key)
        return value
    }

    func store(_ value: PreviewValue, for key: PreviewKey) {
        if entries[key] != nil {
            drop(key)
        }
        entries[key] = value
        usage.append(key)
        evictIfNeeded()
    }

    /// A private directory for one encode. Callers pass it to `--out`, so two files
    /// with the same stem can never overwrite each other.
    func makeScratchDirectory() -> URL {
        scratchCounter += 1
        let dir = root.appendingPathComponent("e\(scratchCounter)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Called when the app quits.
    func purge() {
        entries.removeAll()
        usage.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated var scratchRoot: URL { root }

    // MARK: - LRU bookkeeping

    private func touch(_ key: PreviewKey) {
        guard let index = usage.firstIndex(of: key) else {
            usage.append(key)
            return
        }
        usage.remove(at: index)
        usage.append(key)
    }

    private func drop(_ key: PreviewKey) {
        if let value = entries.removeValue(forKey: key) {
            // Remove the whole per-encode directory, not just the file inside it.
            try? FileManager.default.removeItem(at: value.temporaryURL.deletingLastPathComponent())
        }
        usage.removeAll { $0 == key }
    }

    private func evictIfNeeded() {
        while usage.count > limit, let oldest = usage.first {
            drop(oldest)
        }
    }

    // MARK: - Housekeeping

    /// Deletes scratch roots left behind by previous runs that crashed or were force-quit.
    /// Anything whose owning pid is gone, or that is over a day old, goes.
    private static func sweepAbandonedScratchDirectories(under base: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: base,
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        let livePID = ProcessInfo.processInfo.processIdentifier
        for child in children where child.standardizedFileURL != current.standardizedFileURL {
            let pid = Int32(child.lastPathComponent.split(separator: "-").first.map(String.init) ?? "") ?? -1
            let stale: Bool
            if pid == livePID {
                stale = false
            } else if pid > 0, kill(pid, 0) == 0 {
                stale = false // another Squish is genuinely running
            } else {
                stale = true
            }
            if stale {
                try? fm.removeItem(at: child)
            }
        }
    }
}
