import Foundation

/// What the user asked the output pixels to be.
///
/// The aspect ratio is always kept - there is no form of this type that can stretch an
/// image, by design. A number is either a bound on one side (the other follows), a box
/// both sides have to fit inside, or a scale factor.
///
/// Textual form, as accepted by `--resize` and as written back by `description`:
///
/// | Spec        | Meaning                                                     |
/// |-------------|-------------------------------------------------------------|
/// | `2000x2000` | fit inside that box - each image's long edge lands on it     |
/// | `2000`      | same as `2000x2000`                                         |
/// | `2000x`     | width exactly 2000, height follows                          |
/// | `x1200`     | height exactly 1200, width follows                          |
/// | `50%`       | both sides scaled to 50%                                    |
///
/// Enlarging is allowed by default (`200%` and `8000x` really do upscale, Lanczos);
/// `allowEnlarge == false` turns the spec into a ceiling, which is what the older
/// `--max-dimension N` meant.
public struct ResizeSpec: Hashable, Sendable, CustomStringConvertible {

    public enum Target: Hashable, Sendable {
        /// Fit inside `width` x `height`, ratio kept. Orientation-agnostic, so a mixed
        /// batch of portraits and landscapes all come out inside the same box.
        case box(width: Int, height: Int)
        /// Width is exactly this; height follows the ratio.
        case width(Int)
        /// Height is exactly this; width follows the ratio.
        case height(Int)
        /// Scale both sides by this percentage (100 = unchanged).
        case percent(Double)
    }

    /// Largest side a resize may produce, and the largest total it may allocate
    /// (4 bytes per pixel, so 100 Mpx is a 400 MB buffer). Guards against a typo in a
    /// percentage asking for a gigapixel image.
    public static let maxSide = 20_000
    public static let maxPixels = 100_000_000

    public var target: Target
    public var allowEnlarge: Bool

    public init(target: Target, allowEnlarge: Bool = true) {
        self.target = target
        self.allowEnlarge = allowEnlarge
    }

    /// The pre-`--resize` spelling: a ceiling on the long edge.
    public static func maxDimension(_ value: Int) -> ResizeSpec {
        ResizeSpec(target: .box(width: value, height: value), allowEnlarge: false)
    }

    // MARK: - Parsing

    /// Parses the textual form. Throws `SquishError.usage` with the offending text.
    public static func parse(_ raw: String) throws -> ResizeSpec {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { throw invalid(raw) }

        if text.hasSuffix("%") {
            let body = String(text.dropLast())
            guard let value = Double(body), value.isFinite, value >= 1, value <= 2000 else {
                throw SquishError.usage("--resize percentage must be 1-2000, got '\(raw)'")
            }
            return ResizeSpec(target: .percent(value))
        }

        if let separator = text.firstIndex(where: { $0 == "x" || $0 == "×" }) {
            let left = String(text[text.startIndex..<separator])
            let right = String(text[text.index(after: separator)...])
            // A second separator ("2000x2000x10") is junk, not a third dimension.
            if right.contains("x") || right.contains("×") { throw invalid(raw) }
            switch (left.isEmpty, right.isEmpty) {
            case (true, true):
                throw invalid(raw)
            case (false, true):
                return ResizeSpec(target: .width(try side(left, raw: raw)))
            case (true, false):
                return ResizeSpec(target: .height(try side(right, raw: raw)))
            case (false, false):
                return ResizeSpec(target: .box(width: try side(left, raw: raw),
                                               height: try side(right, raw: raw)))
            }
        }

        // A bare number is the long-edge box. Anything else is not a spec at all, so
        // say what a spec looks like rather than complaining about a side's range.
        guard text.allSatisfy(\.isNumber) else { throw invalid(raw) }
        let value = try side(text, raw: raw)
        return ResizeSpec(target: .box(width: value, height: value))
    }

    private static func side(_ text: String, raw: String) throws -> Int {
        guard let value = Int(text), value >= 1, value <= maxSide else {
            throw SquishError.usage("--resize sides must be 1-\(maxSide) px, got '\(raw)'")
        }
        return value
    }

    private static func invalid(_ raw: String) -> SquishError {
        .usage("--resize expects WxH, Wx, xH, N or P% (e.g. 2000x2000, 2000x, x1200, 50%), got '\(raw)'")
    }

    public var description: String {
        switch target {
        case .box(let width, let height): return "\(width)x\(height)"
        case .width(let width): return "\(width)x"
        case .height(let height): return "x\(height)"
        case .percent(let percent):
            let rounded = percent.rounded()
            return abs(percent - rounded) < 0.001
                ? "\(Int(rounded))%"
                : String(format: "%.2f%%", percent)
        }
    }

    // MARK: - Applying

    /// The size this spec produces for a source of `width` x `height`, ratio kept and
    /// both sides at least 1. Returns the input size unchanged when there is nothing to do.
    public func outputSize(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        var ratio: Double
        switch target {
        case .box(let boxWidth, let boxHeight):
            ratio = min(Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
        case .width(let target):
            ratio = Double(target) / Double(width)
        case .height(let target):
            ratio = Double(target) / Double(height)
        case .percent(let percent):
            ratio = percent / 100
        }
        if !allowEnlarge { ratio = min(ratio, 1) }
        guard ratio > 0, ratio.isFinite else { return (width, height) }

        var outWidth = max(1, Int((Double(width) * ratio).rounded()))
        var outHeight = max(1, Int((Double(height) * ratio).rounded()))

        // Clamp to the safety ceilings, keeping the ratio.
        let overshoot = max(Double(outWidth) / Double(ResizeSpec.maxSide),
                            Double(outHeight) / Double(ResizeSpec.maxSide),
                            (Double(outWidth) * Double(outHeight) / Double(ResizeSpec.maxPixels)).squareRoot())
        if overshoot > 1 {
            outWidth = max(1, Int((Double(outWidth) / overshoot).rounded(.down)))
            outHeight = max(1, Int((Double(outHeight) / overshoot).rounded(.down)))
        }
        return (outWidth, outHeight)
    }
}
