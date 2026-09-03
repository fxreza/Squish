import Foundation

/// Every failure the core can produce. `description` is what the CLI prints, so each case
/// names the thing that went wrong concretely enough to act on.
public enum SquishError: Error, CustomStringConvertible, Sendable {
    case usage(String)
    case noInputs
    case missingBinary(name: String, searched: [String])
    case decodeFailed(url: URL, reason: String)
    case unsupportedInput(url: URL)
    case toolFailed(tool: String, status: Int32, message: String)
    case metricUnavailable
    case metricParse(tool: String, output: String)
    case io(String)
    case wouldOverwriteInput(url: URL)
    case clipboardEmpty
    case clipboardWriteFailed

    public var description: String {
        switch self {
        case .usage(let m):
            return m
        case .noInputs:
            return "no input files. Pass one or more files or directories, or use --clipboard."
        case .missingBinary(let name, let searched):
            return """
            missing helper binary '\(name)'. Looked in:
            \(searched.map { "  - " + $0 }.joined(separator: "\n"))
            Run scripts/vendor-codecs.sh to populate vendor/bin, or set SQUISH_BIN_DIR.
            """
        case .decodeFailed(let url, let reason):
            return "could not decode \(url.path): \(reason)"
        case .unsupportedInput(let url):
            return "unsupported input file: \(url.path)"
        case .toolFailed(let tool, let status, let message):
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) exited with status \(status)\(m.isEmpty ? "" : ": " + m)"
        case .metricUnavailable:
            return "no perceptual metric binary found (ssimulacra2 or dssim). vlossless needs one."
        case .metricParse(let tool, let output):
            return "could not parse \(tool) output: \(output.prefix(200))"
        case .io(let m):
            return m
        case .wouldOverwriteInput(let url):
            return "refusing to overwrite the input \(url.path); pass --inplace or use --out/--suffix."
        case .clipboardEmpty:
            return "the pasteboard does not contain an image."
        case .clipboardWriteFailed:
            return "could not write the compressed image back to the pasteboard."
        }
    }
}
