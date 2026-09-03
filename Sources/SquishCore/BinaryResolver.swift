import Foundation

/// Finds the bundled helper binaries.
///
/// Search order (first hit wins):
///   0. `$SQUISH_BIN_DIR` - colon separated. Development / test escape hatch only; it is not
///      set in the shipped app. This is the only addition to the order the spec lays out.
///   1. `Resources/bin` next to the running executable. Covers the app bundle, where the CLI
///      lives at `Squish.app/Contents/Resources/bin/squish` next to its helpers, and the
///      AppKit binary at `Contents/MacOS/SquishApp` reaching `../Resources/bin`.
///   2. `vendor/bin` at the project root, found by walking up from the executable and from the
///      current directory looking for a `Package.swift` sibling. Covers `swift run` in a checkout.
///   3. `$PATH`.
public struct BinaryResolver: Sendable {
    public static let shared = BinaryResolver()

    private let cache = Locked([String: URL]())

    public init() {}

    /// The directories that will be searched, in order, as strings (for error messages).
    public var searchPaths: [String] { Self.directories().map(\.path) }

    public func exists(_ name: String) -> Bool {
        (try? url(for: name)) != nil
    }

    public func url(for name: String) throws -> URL {
        if let hit = cache.withLock({ $0[name] }) { return hit }
        for dir in Self.directories() {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                cache.withLock { $0[name] = candidate }
                return candidate
            }
        }
        throw SquishError.missingBinary(name: name, searched: searchPaths)
    }

    private static func directories() -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url else { return }
            let std = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue else { return }
            if seen.insert(std.path).inserted { dirs.append(std) }
        }

        // 0. explicit override
        if let raw = ProcessInfo.processInfo.environment["SQUISH_BIN_DIR"] {
            for part in raw.split(separator: ":") where !part.isEmpty {
                add(URL(fileURLWithPath: String(part)))
            }
        }

        // 1. next to the executable
        let exeDir = executableDirectory()
        add(exeDir)
        add(exeDir?.appendingPathComponent("Resources/bin"))
        add(exeDir?.deletingLastPathComponent().appendingPathComponent("Resources/bin"))

        // 2. vendor/bin at a project root above us or above the working directory
        for start in [exeDir, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)].compactMap({ $0 }) {
            if let root = projectRoot(startingAt: start) {
                add(root.appendingPathComponent("vendor/bin"))
            }
        }

        // 3. PATH
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for part in path.split(separator: ":") where !part.isEmpty {
                add(URL(fileURLWithPath: String(part)))
            }
        }
        return dirs
    }

    private static func executableDirectory() -> URL? {
        if let exe = Bundle.main.executableURL {
            return exe.resolvingSymlinksInPath().deletingLastPathComponent()
        }
        let argv0 = CommandLine.arguments.first ?? ""
        guard !argv0.isEmpty else { return nil }
        return URL(fileURLWithPath: argv0).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    private static func projectRoot(startingAt start: URL) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            let manifest = dir.appendingPathComponent("Package.swift")
            let vendor = dir.appendingPathComponent("vendor/bin")
            if FileManager.default.fileExists(atPath: manifest.path)
                || FileManager.default.fileExists(atPath: vendor.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
