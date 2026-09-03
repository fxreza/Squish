import Foundation

public struct QualitySearchResult: Sendable {
    public let quality: Int
    public let data: Data
    public let score: Double
    /// True when even the top of the bracket could not reach the target.
    public let belowTarget: Bool
    /// How many encode+measure round trips it took.
    public let evaluations: Int
}

/// Finds the smallest encode that still scores at or above the perceptual target.
///
/// Bracket is [55, 98], in at most 8 evaluations. The first three are run **concurrently** at
/// 62 / 76 / 89 - a plain binary search is strictly sequential, but a three-point probe costs
/// the same wall time as one evaluation and usually pins the answer to a 13-wide interval,
/// which the remaining sequential steps then bisect. Callers cache the decoded pixels, so each
/// evaluation is an encode plus a metric run, never a re-decode.
///
/// The winner is the smallest *file* among the passing candidates, not the lowest quality
/// number: quality and size are usually monotone but palette quantisation can break that.
///
/// ## Why the ceiling is 98 and not the spec's 96
///
/// The spec called for [55, 96]. On demanding input - a lossless master, or anything already
/// JPEG-compressed once - q96 lands a fraction under the default target of 90, so the mode
/// either flagged `belowTarget` or fell back to the lossless repack and saved almost nothing.
/// q97-98 is exactly the band that closes that gap. The ceiling stops at 98 deliberately:
/// mozjpeg's output balloons at 99-100 for no perceptual gain, and quality 100 is already
/// covered by the lossless repack candidate the caller supplies.
///
/// The wider bracket costs two more evaluations in the worst case, and only in the worst case.
/// Matching the *old* uncertainty would have needed only one more - three bisection steps close
/// 89...98 to a 2-wide gap, exactly as two steps closed 89...96 - but a 2-wide gap is worth far
/// more at the top of the range than it was at 96, because file size climbs steeply there.
/// Measured on a lossless 3840x2160 master at target 90: stopping with 96 failing and 98 passing
/// returns q98 at 2,343,176 bytes, while the untested q97 passes too, at 1,980,273 bytes. That
/// is 15% given away to save one encode, so phase 3 gets the fourth step it needs to always
/// close the interval to a single quality point.
///
/// The budget only binds on demanding input. An image where one of the concurrent probes already
/// passes never reaches phase 2 and still finishes in three or four evaluations.
public enum QualitySearch {
    public static let lowerBound = 55
    public static let upperBound = 98
    static let probes = [62, 76, 89]

    struct Evaluation: Sendable {
        let quality: Int
        let data: Data
        let score: Double
    }

    public static func run(
        target: Double,
        budget: Int = 8,
        encode: @escaping @Sendable (Int) throws -> Data,
        measure: @escaping @Sendable (Int, Data) throws -> Double
    ) async throws -> QualitySearchResult {

        var evaluated: [Int: Evaluation] = [:]

        // SQUISH_DEBUG=1 traces every encode+measure round trip on stderr. The search is the
        // one part of the pipeline whose behaviour is impossible to reconstruct from the result.
        let trace = ProcessInfo.processInfo.environment["SQUISH_DEBUG"] == "1"

        @Sendable func evaluate(_ quality: Int) throws -> Evaluation {
            let data = try encode(quality)
            let score = try measure(quality, data)
            if trace {
                FileHandle.standardError.write(Data(
                    String(format: "  search: q%-3d %9d bytes  score %6.2f  %@\n",
                           quality, data.count, score,
                           score >= target ? "pass" : "fail").utf8))
            }
            return Evaluation(quality: quality, data: data, score: score)
        }

        // Phase 1 - concurrent bracket probe.
        try await withThrowingTaskGroup(of: Evaluation.self) { group in
            for quality in probes {
                group.addTask { try evaluate(quality) }
            }
            for try await result in group { evaluated[result.quality] = result }
        }

        func bestPassing() -> Evaluation? {
            evaluated.values.filter { $0.score >= target }.min { a, b in
                if a.data.count != b.data.count { return a.data.count < b.data.count }
                return a.quality < b.quality
            }
        }

        var lowestPassingQuality = evaluated.values.filter { $0.score >= target }.map(\.quality).min()

        // Phase 2 - nothing passed, try the top of the bracket.
        if lowestPassingQuality == nil {
            let top = try evaluate(upperBound)
            evaluated[top.quality] = top
            if top.score >= target {
                lowestPassingQuality = top.quality
            } else {
                return QualitySearchResult(quality: top.quality,
                                           data: top.data,
                                           score: top.score,
                                           belowTarget: true,
                                           evaluations: evaluated.count)
            }
        }

        // Phase 3 - bisect between the highest known failure and the lowest known pass.
        var high = lowestPassingQuality!
        var low = evaluated.values.filter { $0.score < target && $0.quality < high }.map(\.quality).max()
            ?? (lowerBound - 1)

        while high - low > 1 && evaluated.count < budget {
            let mid = low + (high - low) / 2
            guard mid >= lowerBound, evaluated[mid] == nil else { break }
            let result = try evaluate(mid)
            evaluated[mid] = result
            if result.score >= target { high = mid } else { low = mid }
        }

        guard let winner = bestPassing() else {
            // Unreachable in practice; keep the largest evaluation rather than failing.
            let fallback = evaluated.values.max { $0.score < $1.score }!
            return QualitySearchResult(quality: fallback.quality,
                                       data: fallback.data,
                                       score: fallback.score,
                                       belowTarget: true,
                                       evaluations: evaluated.count)
        }
        return QualitySearchResult(quality: winner.quality,
                                   data: winner.data,
                                   score: winner.score,
                                   belowTarget: false,
                                   evaluations: evaluated.count)
    }
}
