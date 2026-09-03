import Foundation

/// A scratch directory that deletes itself. Helpers such as cwebp insist on real files, and
/// the perceptual metrics compare two files on disk, so a handful of temporaries per image is
/// unavoidable. Everything is kept under one directory so cleanup is a single call.
public final class TempWorkspace: @unchecked Sendable {
    public let root: URL
    private let counter = Locked(0)

    public init(label: String = "squish") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    public func path(_ name: String, ext: String) -> URL {
        let n = counter.withLock { (v: inout Int) -> Int in v += 1; return v }
        return root.appendingPathComponent("\(name)-\(n).\(ext)")
    }

    @discardableResult
    public func write(_ data: Data, name: String, ext: String) throws -> URL {
        let url = path(name, ext: ext)
        do { try data.write(to: url, options: .atomic) }
        catch { throw SquishError.io("could not write temp file \(url.path): \(error.localizedDescription)") }
        return url
    }
}
