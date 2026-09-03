import Foundation

/// Version strings, read from the bundle rather than hardcoded, so
/// `scripts/build-app.sh` stays the single source of truth for what version
/// this is. Mirrors how Klip reads `CFBundleShortVersionString`, with the build
/// number alongside it because an ad-hoc dev build and a release can otherwise
/// look identical.
enum AppInfo {

    static var name: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "Squish"
    }

    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    /// "1.0.0 (1)", or just "1.0.0" when the build number adds nothing.
    static var versionDisplay: String {
        let version = shortVersion
        let build = buildNumber
        guard build != "—", build != version else { return version }
        return "\(version) (\(build))"
    }

    static var copyright: String {
        (Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String) ?? ""
    }
}
