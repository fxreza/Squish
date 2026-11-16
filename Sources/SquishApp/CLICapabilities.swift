import Foundation

/// One-shot probe of the bundled `squish` binary, so the app degrades gracefully
/// against a CLI that is older (or newer) than it is.
///
/// Three things are probed, all cheaply and without touching any user file:
///
///  * **the JPEG mode token.** The mode is called `jpeg`; it used to be called `web`.
///    Running `squish jpeg` with no inputs either reports "unknown mode 'jpeg'"
///    (old CLI - fall back to `web`) or "no input files" (new CLI - `jpeg` is good).
///  * **`--resize`.** The 1.1 resize grammar; an older CLI only has `--max-dimension`.
///  * **`--no-verify`.** Previews only need the output's byte count, never its
///    perceptual score, so skipping verification roughly halves preview cost for
///    `jpeg`/`webp`. If the flag isn't in `--help`, don't pass it.
///
/// The probe runs once, lazily, on the first access and is then cached for the
/// lifetime of the process.
final class CLICapabilities: @unchecked Sendable {

    static let shared = CLICapabilities()

    let jpegModeToken: String
    let supportsNoVerify: Bool
    /// `--resize` (1.1+). Older CLIs only have `--max-dimension`.
    let supportsResize: Bool
    let binaryPath: String?

    private init() {
        let path = BinaryLocator.squishPath()
        binaryPath = path

        guard let path else {
            jpegModeToken = "jpeg"
            supportsNoVerify = false
            supportsResize = false
            return
        }

        let modeProbe = CLICapabilities.runSync(path: path, arguments: ["jpeg"])
        let combined = modeProbe.stdout + modeProbe.stderr
        jpegModeToken = combined.contains("unknown mode") ? "web" : "jpeg"

        let help = CLICapabilities.runSync(path: path, arguments: ["--help"])
        let helpText = help.stdout + help.stderr
        supportsNoVerify = helpText.contains("--no-verify")
        supportsResize = helpText.contains("--resize")
    }

    /// Blocking, but only ever used for the two trivial probes above, which do no work
    /// and exit immediately.
    private static func runSync(path: String, arguments: [String]) -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ("", "")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
