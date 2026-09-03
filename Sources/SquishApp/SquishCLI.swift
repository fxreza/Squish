import Foundation

/// Async, one-file-at-a-time wrapper around the bundled `squish` CLI.
///
/// The window never batches any more: every compression is a preview of exactly one
/// file into a scratch directory, run concurrently by `PreviewCoordinator` under a
/// bounded task group. That makes cancellation per-file and keeps the JSON parsing
/// trivial - one process, one line.
enum SquishCLI {

    enum CLIError: LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case noResult(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Couldn't find the squish CLI binary. Reinstall Squish.app."
            case .launchFailed(let detail):
                return "Couldn't start squish: \(detail)"
            case .noResult(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "squish produced no result." : trimmed
            }
        }
    }

    /// Compresses `url` with `settings` into `directory` and returns the parsed JSON line.
    ///
    /// `--suffix ""` keeps the scratch filename equal to the input stem, so the caller
    /// can hand the file straight on. Each call gets its own directory, so stems never
    /// collide between files.
    static func preview(url: URL,
                        settings: EncodeSettings,
                        into directory: URL) async throws -> RunResult {
        var args: [String] = [settings.mode.cliArgument]
        args += settings.encodeArguments
        args += ["--out", directory.path, "--suffix", ""]
        if settings.mode.usesQuality && CLICapabilities.shared.supportsNoVerify {
            // Previews only need the byte count; the perceptual score costs a whole
            // extra metric run per file. vlossless always needs it - it *is* the search.
            args.append("--no-verify")
        }
        args += ["--json", url.path]

        let output = try await run(arguments: args)

        for line in output.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let result = try? JSONDecoder().decode(RunResult.self, from: data) else { continue }
            return result
        }
        throw CLIError.noResult(output.stderr)
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs the CLI to completion. Cooperates with task cancellation by terminating
    /// the subprocess, so a superseded preview stops burning CPU immediately.
    static func run(arguments: [String]) async throws -> Output {
        guard let binary = CLICapabilities.shared.binaryPath else {
            throw CLIError.binaryNotFound
        }

        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let collected = OutputBox()
                let group = DispatchGroup()

                // Drain both pipes on their own threads. Reading them serially would
                // deadlock as soon as one filled its 64 KB buffer while we blocked on
                // the other.
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    collected.appendStdout(data)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    collected.appendStderr(data)
                    group.leave()
                }

                process.terminationHandler = { proc in
                    let status = proc.terminationStatus
                    group.notify(queue: .global(qos: .userInitiated)) {
                        continuation.resume(returning: Output(status: status,
                                                              stdout: collected.stdoutString,
                                                              stderr: collected.stderrString))
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CLIError.launchFailed(error.localizedDescription))
                    return
                }

                // Register after launch so a cancellation that raced the start still lands.
                handle.adopt(process)
            }
        } onCancel: {
            handle.terminate()
        }
    }
}

/// Bridges structured cancellation (which can fire from any thread, at any time)
/// onto the `Process` created inside the continuation.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.process = process
        lock.unlock()
        if alreadyCancelled {
            process.terminate()
        }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

/// Thread-safe accumulator for the two pipe-reading threads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendStdout(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendStderr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
