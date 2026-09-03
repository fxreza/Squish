import Foundation

/// Mirrors the JSON line shape emitted by `squish --json`, documented in docs/SPEC.md:
///
///   {"input":"/p/a.tif","output":"/p/a-squish.jpg","bytesIn":9123456,"bytesOut":812345,
///    "savedPct":91.1,"quality":84,"score":92.4,"mode":"jpeg","ok":true,"error":null}
///
/// Every field past `input`/`ok` is optional so a failed line, or a CLI that grows a
/// key we don't know about, still decodes.
struct RunResult: Codable, Sendable {
    let input: String
    let output: String?
    let bytesIn: Int64?
    let bytesOut: Int64?
    let savedPct: Double?
    let quality: Int?
    let score: Double?
    let mode: String?
    let ok: Bool
    let error: String?
    let belowTarget: Bool?

    var fileName: String {
        (input as NSString).lastPathComponent
    }
}

/// Main-actor only: `ByteCountFormatter` isn't Sendable or thread-safe, and every
/// caller (table cells, the footer) is already on the main actor.
@MainActor
enum ByteFormat {
    /// Shared formatter - ByteCountFormatter is not cheap to build, and the table
    /// rebuilds every value cell on each preview that lands.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static func string(for bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
