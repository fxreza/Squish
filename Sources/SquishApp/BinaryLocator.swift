import Foundation

/// Finds the `squish` CLI binary the app should shell out to.
///
/// In the shipped .app it always lives at Contents/Resources/bin/squish next to
/// SquishApp itself. During development (running `swift build` / `swift run`
/// directly, outside any .app bundle) that path doesn't exist yet, so we fall
/// back to a small search list - the same one the Raycast scripts use - so the
/// app is testable before scripts/build-app.sh has ever run.
enum BinaryLocator {
    static func squishPath() -> String? {
        let fm = FileManager.default

        // 1. Bundled location: Contents/Resources/bin/squish
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/squish")
        if fm.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        // 2. Common install / dev fallback locations.
        let candidates = [
            "/usr/local/bin/squish",
            "/Applications/Squish.app/Contents/Resources/bin/squish",
            NSHomeDirectory() + "/Applications/Squish.app/Contents/Resources/bin/squish",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }

        // 3. Dev build output next to this executable's build dir
        // (…/.build/release/squish or …/.build/debug/squish), useful when
        // running SquishApp straight out of `swift build` during development.
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            let sibling = exeDir.appendingPathComponent("squish")
            if fm.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }

        // 4. PATH lookup as a last resort.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/squish"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }
}
