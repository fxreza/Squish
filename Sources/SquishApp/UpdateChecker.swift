import AppKit

/// Checks a small JSON manifest in the project repository for a newer release.
///
/// Deliberately **not** Sparkle, and deliberately not self-installing. Squish is
/// ad-hoc signed, so a silent in-place replacement would be a real security hole:
/// nothing would verify that what got downloaded is genuinely ours. This finds
/// updates and hands the user to the release page; installing stays deliberate.
/// Moving to Sparkle later means a Developer ID, notarisation and EdDSA signing.
///
/// The feed is a plain JSON file in the repo rather than the GitHub Releases API,
/// because that can be corrected instantly. Shipping a bad build means editing one
/// file and pushing, with no release to cut and no API rate limit. `critical` exists
/// for exactly that case: it overrides a user's "skip this version".
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// Shape of `updates/latest.json` in the repository.
    private struct Manifest: Decodable {
        let version: String
        let build: String?
        let critical: Bool?
        let notes: String?
        let download: String?
        let minimumSystemVersion: String?
    }

    enum Outcome {
        case upToDate
        case updateAvailable(version: String)
        case failed(String)
    }

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let skippedVersion = "updateSkippedVersion"
        static let automaticEnabled = "updateAutomaticCheckEnabled"
    }

    /// Quiet background checks run at most once a day. A user-initiated check
    /// ignores this entirely and always hits the network.
    private let automaticInterval: TimeInterval = 24 * 60 * 60

    private var inFlight = false

    private var defaults: UserDefaults { Preferences.shared.defaults }

    private var feedURL: URL? {
        guard let raw = Bundle.main.infoDictionary?["SquishUpdateFeedURL"] as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var repositoryURL: URL? {
        guard let raw = Bundle.main.infoDictionary?["SquishRepositoryURL"] as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var automaticChecksEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.automaticEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.automaticEnabled)
        }
        set { defaults.set(newValue, forKey: Key.automaticEnabled) }
    }

    // MARK: - Entry points

    /// Called at launch. Silent unless there is genuinely something newer, so it can
    /// never interrupt someone who just wanted to compress an image.
    func checkInBackground() {
        guard automaticChecksEnabled else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= automaticInterval else { return }
        Task { _ = await check(userInitiated: false) }
    }

    /// The "Check for Updates…" menu item. Always hits the network, and always
    /// reports back - including "you are up to date", which is the whole reason
    /// someone reaches for it.
    @discardableResult
    func checkNow() async -> Outcome {
        await check(userInitiated: true)
    }

    // MARK: - The check itself

    @discardableResult
    private func check(userInitiated: Bool) async -> Outcome {
        guard !inFlight else { return .failed("A check is already running.") }
        guard let feedURL else {
            let message = "No update feed is configured for this build."
            if userInitiated { presentFailure(message) }
            return .failed(message)
        }

        inFlight = true
        defer { inFlight = false }

        do {
            var request = URLRequest(url: feedURL)
            // The feed is a small file that changes rarely; never serve a cached copy
            // for a user-initiated check or "check for updates" would lie.
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = userInitiated ? 15 : 8

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.badStatus(http.statusCode)
            }

            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            defaults.set(Date(), forKey: Key.lastCheck)

            let current = AppInfo.shortVersion
            guard Self.isNewer(manifest.version, than: current) else {
                if userInitiated { presentUpToDate(current: current) }
                return .upToDate
            }

            // A skipped version stays skipped, unless the release is marked critical -
            // that flag exists so a broken build can still be recalled.
            let critical = manifest.critical ?? false
            if !critical, !userInitiated,
               defaults.string(forKey: Key.skippedVersion) == manifest.version {
                return .upToDate
            }

            presentUpdate(manifest, current: current, critical: critical)
            return .updateAvailable(version: manifest.version)
        } catch {
            let message = Self.describe(error)
            if userInitiated { presentFailure(message) }
            return .failed(message)
        }
    }

    private enum UpdateError: Error { case badStatus(Int) }

    private static func describe(_ error: Error) -> String {
        if case UpdateError.badStatus(let code) = error {
            if code == 404 { return "The update feed was not found (404). The release may not be published yet." }
            return "The update server returned HTTP \(code)."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection."
            case .timedOut:
                return "The update server did not respond in time."
            default:
                return urlError.localizedDescription
            }
        }
        if error is DecodingError {
            return "The update feed is malformed and could not be read."
        }
        return error.localizedDescription
    }

    // MARK: - Version comparison

    /// Compares dotted numeric versions component by component, so 1.10.0 correctly
    /// beats 1.9.0 - which a string comparison would get backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parse(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .prefix(4)
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: - Presentation

    private func presentUpdate(_ manifest: Manifest, current: String, critical: Bool) {
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .informational
        alert.messageText = critical
            ? "Squish \(manifest.version) is an important update."
            : "Squish \(manifest.version) is available."
        var body = "You have \(current)."
        if critical {
            body += " This release fixes a significant problem and is worth installing now."
        }
        if let minimum = manifest.minimumSystemVersion {
            body += "\nRequires macOS \(minimum) or later."
        }
        alert.informativeText = body

        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !critical { alert.addButton(withTitle: "Skip This Version") }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let destination = manifest.download.flatMap(URL.init(string:))
                ?? manifest.notes.flatMap(URL.init(string:))
                ?? repositoryURL
            if let destination { NSWorkspace.shared.open(destination) }
        case .alertThirdButtonReturn:
            defaults.set(manifest.version, forKey: Key.skippedVersion)
        default:
            break
        }
    }

    private func presentUpToDate(current: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Squish is up to date."
        alert.informativeText = "You are running \(current), which is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if repositoryURL != nil { alert.addButton(withTitle: "Open Releases Page") }
        if alert.runModal() == .alertSecondButtonReturn, let repositoryURL {
            NSWorkspace.shared.open(repositoryURL.appendingPathComponent("releases"))
        }
    }
}
