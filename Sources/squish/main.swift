import Foundation
import SquishCore

SquishRuntime.prepare()

// MARK: - Output helpers

final class ConsoleWriter: @unchecked Sendable {
    private let lock = NSLock()

    func out(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func err(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

let console = ConsoleWriter()

func humanBytes(_ count: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(count)
    var unit = 0
    while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
    return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
}

func describe(_ outcome: FileOutcome) -> String {
    guard outcome.ok, let output = outcome.output else {
        return "\(outcome.input): \(outcome.error ?? "failed")"
    }
    var parts = ["\(outcome.input) -> \(output)",
                 "\(humanBytes(outcome.bytesIn)) -> \(humanBytes(outcome.bytesOut))",
                 String(format: "%+.1f%%", -outcome.savedPct)]
    if let quality = outcome.quality { parts.append("q\(quality)") }
    var trailing: [String] = []
    if let chroma = outcome.chroma { trailing.append(chroma) }
    if let score = outcome.score { trailing.append(String(format: "score %.1f", score)) }
    if outcome.belowTarget == true { trailing.append("below target") }
    if !trailing.isEmpty { parts.append("(" + trailing.joined(separator: ", ") + ")") }
    return parts.joined(separator: "  ")
}

func emit(_ outcome: FileOutcome, json: Bool) {
    if json {
        console.out(outcome.jsonLine)
    } else {
        console.out(describe(outcome))
    }
}

func fail(_ message: String) -> Never {
    console.err("squish: \(message)")
    exit(1)
}

// MARK: - Runners

func runFiles(_ options: SquishOptions) async -> Int32 {
    let pipeline = Pipeline()
    do {
        let outcomes = try await pipeline.run(options: options) { event in
            switch event {
            case .started(let index, let total, let url):
                console.err("[\(index + 1)/\(total)] \(url.lastPathComponent)")
            case .finished(_, _, let outcome):
                emit(outcome, json: options.json)
                if !outcome.ok {
                    console.err("squish: \(outcome.input): \(outcome.error ?? "failed")")
                }
            }
        }
        let failures = outcomes.filter { !$0.ok }.count
        let totalIn = outcomes.filter(\.ok).reduce(0) { $0 + $1.bytesIn }
        let totalOut = outcomes.filter(\.ok).reduce(0) { $0 + $1.bytesOut }
        if outcomes.count > 1 {
            let saved = totalIn > 0 ? (Double(totalIn - totalOut) / Double(totalIn)) * 100 : 0
            console.err(String(format: "%d file(s), %@ -> %@ (%.1f%% smaller)%@",
                               outcomes.count, humanBytes(totalIn), humanBytes(totalOut), saved,
                               failures > 0 ? ", \(failures) failed" : ""))
        }
        return failures > 0 ? 1 : 0
    } catch let error as SquishError {
        console.err("squish: \(error.description)")
        return 1
    } catch {
        console.err("squish: \(error.localizedDescription)")
        return 1
    }
}

func runClipboard(_ options: SquishOptions) async -> Int32 {
    do {
        let source = try Clipboard.readImage()
        let decoded = source.image
        let bytesIn = source.sourceByteCount
        let result = try await Pipeline().compress(decoded: decoded,
                                                   originalFileBytes: nil,
                                                   options: options)
        try Clipboard.writeImage(result.data, fileExtension: result.fileExtension)
        let outcome = FileOutcome(input: "clipboard",
                                  output: "clipboard",
                                  bytesIn: bytesIn,
                                  bytesOut: result.data.count,
                                  quality: result.quality,
                                  score: result.score,
                                  mode: options.mode.rawValue,
                                  ok: true,
                                  belowTarget: result.belowTarget,
                                  chroma: result.chroma)
        emit(outcome, json: options.json)
        return 0
    } catch let error as SquishError {
        if options.json {
            console.out(FileOutcome(input: "clipboard",
                                    mode: options.mode.rawValue,
                                    ok: false,
                                    error: error.description).jsonLine)
        }
        console.err("squish: \(error.description)")
        return 1
    } catch {
        console.err("squish: \(error.localizedDescription)")
        return 1
    }
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty {
    console.err(Arguments.helpText)
    exit(1)
}

do {
    switch try Arguments.parse(argv) {
    case .help:
        console.out(Arguments.helpText)
        exit(0)
    case .version:
        console.out("squish \(squishVersion)")
        exit(0)
    case .run(let options):
        let status = options.clipboard
            ? await runClipboard(options)
            : await runFiles(options)
        exit(status)
    }
} catch let error as SquishError {
    fail(error.description)
} catch {
    fail(error.localizedDescription)
}
