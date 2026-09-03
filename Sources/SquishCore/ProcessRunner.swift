import Foundation

/// Result of running one helper binary.
public struct ToolResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Minimal thread-safe box; the pipe pumps below run on separate queues.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { self.value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var wrapped: T { withLock { $0 } }
}

// Helper binaries can exit before we finish writing stdin (cjpeg on a malformed PPM, say).
// Without this the write raises SIGPIPE and kills the whole CLI instead of surfacing an error.
private let sigpipeIgnored: Bool = {
    signal(SIGPIPE, SIG_IGN)
    return true
}()

public enum SquishRuntime {
    /// Call once at process start. Idempotent.
    public static func prepare() { _ = sigpipeIgnored }
}

public enum ProcessRunner {
    /// Runs `executable` with `arguments`, optionally feeding `stdin`, and collects both
    /// output streams. stdout and stderr are drained on background queues while stdin is
    /// written, so arbitrarily large payloads cannot deadlock on a full pipe buffer.
    public static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        toolName: String? = nil
    ) throws -> ToolResult {
        SquishRuntime.prepare()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw SquishError.toolFailed(
                tool: toolName ?? executable.lastPathComponent,
                status: -1,
                message: "could not launch \(executable.path): \(error.localizedDescription)")
        }

        let outBox = Locked(Data())
        let errBox = Locked(Data())
        let group = DispatchGroup()

        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            outBox.withLock { $0 = d }
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            errBox.withLock { $0 = d }
        }
        if let data = stdin, let pipe = inPipe {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let handle = pipe.fileHandleForWriting
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }

        process.waitUntilExit()
        group.wait()

        return ToolResult(status: process.terminationStatus,
                          stdout: outBox.wrapped,
                          stderr: errBox.wrapped)
    }

    /// Same as `run`, but throws when the tool exits non-zero.
    @discardableResult
    public static func runChecked(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        toolName: String? = nil
    ) throws -> ToolResult {
        let name = toolName ?? executable.lastPathComponent
        let result = try run(executable: executable, arguments: arguments, stdin: stdin, toolName: name)
        guard result.status == 0 else {
            throw SquishError.toolFailed(tool: name, status: result.status, message: result.stderrText)
        }
        return result
    }
}
