import Foundation

/// A perceptual comparison against the original, normalised so higher is always better.
public protocol PerceptualMetric: Sendable {
    var name: String { get }
    /// 0-100, higher = more similar to the original. 90 is the "visually lossless" mark.
    func score(original: URL, candidate: URL) throws -> Double
}

// MARK: - ssimulacra2

/// `ssimulacra2 <original> <candidate>` prints one float on stdout. Preferred metric: its scale
/// is already the 0-100 scale the spec talks about, with 90 = visually lossless.
public struct Ssimulacra2Metric: PerceptualMetric {
    public let name = "ssimulacra2"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public func score(original: URL, candidate: URL) throws -> Double {
        let exe = try resolver.url(for: name)
        let result = try ProcessRunner.run(executable: exe,
                                           arguments: [original.path, candidate.path],
                                           toolName: name)
        guard result.status == 0 else {
            throw SquishError.toolFailed(tool: name, status: result.status, message: result.stderrText)
        }
        guard let value = Self.parse(result.stdoutText) else {
            throw SquishError.metricParse(tool: name, output: result.stdoutText + result.stderrText)
        }
        // Below ~0 the tool reports "extremely low quality"; clamping keeps the search monotone.
        return min(100, max(0, value))
    }

    /// ---- ONE PLACE TO EDIT IF THE SHIPPED BINARY PRINTS SOMETHING ELSE ----
    /// Current assumption: a single float on stdout, e.g. "87.4231234". Tolerates a label
    /// prefix ("Score: 87.42") and trailing text by taking the first float-looking token.
    static func parse(_ output: String) -> Double? {
        firstFloat(in: output)
    }
}

// MARK: - dssim

/// `dssim <original> <candidate>` prints "<dissimilarity>\t<filename>"; lower is better and 0
/// is identical.
public struct DssimMetric: PerceptualMetric {
    public let name = "dssim"
    private let resolver: BinaryResolver

    public init(resolver: BinaryResolver = .shared) { self.resolver = resolver }

    public func score(original: URL, candidate: URL) throws -> Double {
        let exe = try resolver.url(for: name)
        let result = try ProcessRunner.run(executable: exe,
                                           arguments: [original.path, candidate.path],
                                           toolName: name)
        guard result.status == 0 else {
            throw SquishError.toolFailed(tool: name, status: result.status, message: result.stderrText)
        }
        guard let dissimilarity = Self.parse(result.stdoutText) else {
            throw SquishError.metricParse(tool: name, output: result.stdoutText + result.stderrText)
        }
        return Self.map(dissimilarity: dissimilarity)
    }

    /// ---- ONE PLACE TO EDIT IF THE SHIPPED BINARY PRINTS SOMETHING ELSE ----
    /// Current assumption: "<float>\t<filename>" on stdout, one line per candidate; we take the
    /// first field of the first line.
    static func parse(_ output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) {
            let field = line.split(separator: "\t").first.map(String.init) ?? String(line)
            if let value = firstFloat(in: field) { return value }
        }
        return nil
    }

    /// TODO(calibrate): this is the spec's placeholder mapping, not a fitted one. dssim ~0.0005
    /// lands at 97.8 and ~0.005 at 79.8, which is roughly the right shape, but the constant 45
    /// should be refitted against ssimulacra2 on a real corpus once the vendor agent says which
    /// metric ships. Everything else in the search treats the number as opaque, so only this
    /// line changes.
    static func map(dissimilarity: Double) -> Double {
        let score = 100 * exp(-dissimilarity * 45)
        return min(100, max(0, score))
    }
}

// MARK: - shared parsing

private func firstFloat(in text: String) -> Double? {
    var current = ""
    for character in text {
        if character.isNumber || character == "." || character == "-" || character == "+"
            || character == "e" || character == "E" {
            current.append(character)
        } else {
            if let value = Double(current), !current.isEmpty { return value }
            current = ""
        }
    }
    return Double(current)
}

// MARK: - selection

public enum MetricFactory {
    /// Picks whichever metric binary is actually present, preferring ssimulacra2.
    public static func resolve(_ resolver: BinaryResolver = .shared) -> PerceptualMetric? {
        if resolver.exists("ssimulacra2") { return Ssimulacra2Metric(resolver: resolver) }
        if resolver.exists("dssim") { return DssimMetric(resolver: resolver) }
        return nil
    }
}
