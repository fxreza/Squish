import Foundation

public enum SquishMode: String, Sendable, CaseIterable {
    case jpeg, webp, vlossless

    public var defaultQuality: Int {
        switch self {
        case .jpeg: return 84
        case .webp: return 82
        case .vlossless: return 0 // searched, not fixed
        }
    }
}

public struct SquishOptions: Sendable {
    public var mode: SquishMode
    /// nil means "use the mode default".
    public var quality: Int?
    public var target: Double
    public var outDir: URL?
    public var suffix: String
    public var inplace: Bool
    public var keepMetadata: Bool
    public var maxDimension: Int?
    public var clipboard: Bool
    public var recursive: Bool
    public var json: Bool
    /// Measure the perceptual score of `jpeg`/`webp` output too, so every JSON line carries a
    /// `score` the way the spec's example does. Costs one extra metric run per file; `--no-verify`
    /// turns it off. `vlossless` always measures - the search is defined by it.
    public var verify: Bool
    public var inputs: [URL]

    public init(mode: SquishMode,
                quality: Int? = nil,
                target: Double = 90,
                outDir: URL? = nil,
                suffix: String = "-squish",
                inplace: Bool = false,
                keepMetadata: Bool = false,
                maxDimension: Int? = nil,
                clipboard: Bool = false,
                recursive: Bool = false,
                json: Bool = false,
                verify: Bool = true,
                inputs: [URL] = []) {
        self.mode = mode
        self.quality = quality
        self.target = target
        self.outDir = outDir
        self.suffix = suffix
        self.inplace = inplace
        self.keepMetadata = keepMetadata
        self.maxDimension = maxDimension
        self.clipboard = clipboard
        self.recursive = recursive
        self.json = json
        self.verify = verify
        self.inputs = inputs
    }

    public var effectiveQuality: Int { quality ?? mode.defaultQuality }
}

/// One result line. Field order matches the JSON shape in the spec.
public struct FileOutcome: Sendable {
    public var input: String
    public var output: String?
    public var bytesIn: Int
    public var bytesOut: Int
    public var quality: Int?
    public var score: Double?
    public var mode: String
    public var ok: Bool
    public var error: String?
    public var belowTarget: Bool?
    public var chroma: String?

    public var savedPct: Double {
        guard bytesIn > 0, bytesOut > 0 else { return 0 }
        return ((Double(bytesIn) - Double(bytesOut)) / Double(bytesIn)) * 100
    }

    public init(input: String,
                output: String? = nil,
                bytesIn: Int = 0,
                bytesOut: Int = 0,
                quality: Int? = nil,
                score: Double? = nil,
                mode: String,
                ok: Bool,
                error: String? = nil,
                belowTarget: Bool? = nil,
                chroma: String? = nil) {
        self.input = input
        self.output = output
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.quality = quality
        self.score = score
        self.mode = mode
        self.ok = ok
        self.error = error
        self.belowTarget = belowTarget
        self.chroma = chroma
    }

    /// Hand-rolled so the key order matches the spec exactly and no dependency is needed.
    public var jsonLine: String {
        var parts: [String] = []
        parts.append("\"input\":\(JSON.string(input))")
        parts.append("\"output\":\(output.map(JSON.string) ?? "null")")
        parts.append("\"bytesIn\":\(bytesIn)")
        parts.append("\"bytesOut\":\(bytesOut)")
        parts.append("\"savedPct\":\(JSON.number(savedPct, decimals: 1))")
        parts.append("\"quality\":\(quality.map(String.init) ?? "null")")
        parts.append("\"score\":\(score.map { JSON.number($0, decimals: 2) } ?? "null")")
        parts.append("\"mode\":\(JSON.string(mode))")
        parts.append("\"ok\":\(ok ? "true" : "false")")
        parts.append("\"error\":\(error.map(JSON.string) ?? "null")")
        if let belowTarget { parts.append("\"belowTarget\":\(belowTarget ? "true" : "false")") }
        if let chroma { parts.append("\"chroma\":\(JSON.string(chroma))") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

enum JSON {
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "null" }
        return String(format: "%.\(decimals)f", value)
    }
}
