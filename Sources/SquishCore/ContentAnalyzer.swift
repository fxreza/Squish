import Foundation
import Accelerate

/// What the chroma decision came out as, plus the numbers behind it, so the thresholds can be
/// re-checked against new material without instrumenting the code.
public struct ContentAnalysis: Sendable {
    public enum Kind: String, Sendable { case photo, graphics }
    public let kind: Kind
    /// Fraction of horizontally adjacent pixel pairs that are byte-identical in R, G and B,
    /// measured at native resolution. Decision signal.
    public let exactRunFraction: Double
    /// Fraction of coarse-scale pixels whose luma and chroma are both locally flat, after the
    /// image has been box-averaged down to a 192px long edge. Decision signal.
    public let coarseSmoothFraction: Double
    /// Distinct colours after 5-bit-per-channel quantisation, over the sampled tiles.
    /// Diagnostic, plus a tiebreak for the vlossless container choice.
    public let uniqueColors: Int
    /// Fraction of sampled pixels with a luma gradient magnitude above 64/255.
    /// Diagnostic only - see the note on hard edges below.
    public let edgeFraction: Double

    public var isGraphics: Bool { kind == .graphics }
    /// 4:4:4 for graphics, 4:2:0 for photos.
    public var chroma: Chroma { kind == .graphics ? .fourFourFour : .fourTwoZero }
}

public enum Chroma: String, Sendable {
    case fourTwoZero = "4:2:0"
    case fourFourFour = "4:4:4"
    /// cjpeg's `-sample` argument.
    public var cjpegSample: String { self == .fourFourFour ? "1x1" : "2x2" }
}

/// Decides 4:2:0 vs 4:4:4.
///
/// Chroma subsampling throws away three quarters of the colour resolution. On a photograph that
/// is invisible and buys about 30% of the file; on coloured text, UI chrome or a smooth
/// synthetic gradient it produces smearing or chroma banding. So the question is only ever
/// "is this synthetic imagery".
///
/// ## Why the first attempt was wrong
///
/// The original version scaled the image to a 512px long edge with Lanczos and then measured
/// flat runs on 5-bit-quantised colour. That destroyed the very signal it needed: resampling
/// averages sensor noise away, so a real photograph's sky, water and bokeh came back perfectly
/// flat and every photograph classified as graphics. It only looked right because the test
/// fixture was plasma+Gaussian-noise, which is far noisier than any real camera output.
/// Two things follow, and both are now structural:
///
///  * the fine-grained statistics are measured at **native resolution**, on tiles, never on a
///    resampled copy;
///  * "flat" is judged by **byte-exact** equality, not by a quantised bucket, because 5-bit
///    quantisation manufactures flatness out of gentle gradients.
///
/// ## The two signals
///
/// **`exactRunFraction`** - horizontally adjacent pixels that are byte-identical, sampled from
/// tiles at native resolution. Rendered UI is full of runs of literally the same pixel value.
/// A photograph almost never repeats a pixel exactly, even in clear sky, because of sensor
/// noise and the encoder's own dither.
///
/// **`coarseSmoothFraction`** - the image is box-averaged down to a 192px long edge, which
/// removes grain, and then the fraction of pixels that are locally flat in *both* luma and
/// chroma is measured. Photographs carry structure at every scale, so this stays low; smooth
/// synthetic renders collapse to almost nothing once the grain is gone. This is the signal that
/// catches Apple's own wallpapers, which are smooth gradients with heavy synthetic **luma**
/// grain layered on top - at native resolution they are noisier than a real photograph, so no
/// fine-scale statistic can separate them, and the chroma term is what gives them away.
///
/// ## Measured corpus
///
/// Real photographs (a 3840x2160 aerial photo, its HEIC original, q95/q60 JPEG renditions,
/// 1920/800/400/120px downscales, a detail crop, a heavily blurred version, a photograph of
/// printed text), Apple's rendered wallpapers, rendered UI, text, logos with alpha, gradients,
/// and a deliberate mixture of UI with a photograph pasted into it:
///
/// | image                                   | run   | cSmooth | verdict  |
/// |-----------------------------------------|-------|---------|----------|
/// | aerial.heic (real photo, 3840x2160)     | 0.328 |  0.409  | photo    |
/// | master.jpg (q95 4:4:4 of the same)      | 0.407 |  0.405  | photo    |
/// | photo-1920 / 800 / 400 / 120            | 0.207-0.391 | 0.202-0.394 | photo |
/// | photo-lowq.jpg (q60)                    | 0.558 |  0.336  | photo    |
/// | photo detail crop                       | 0.077 |  0.022  | photo    |
/// | photo, heavy blur (bokeh worst case)    | 0.364 |  0.373  | photo    |
/// | photograph of printed text              | 0.059 |  0.036  | photo    |
/// | synthetic plasma fixtures               | 0.003-0.009 | 0.022-0.023 | photo |
/// | "Mac Blue.heic" (rendered gradient)     | 0.054 |  0.510  | graphics |
/// | "iMac Silver.heic" (rendered, grainy)   | 0.069 |  0.650  | graphics |
/// | UI screenshot with a photo pasted in    | 0.826 |  0.699  | graphics |
/// | screenshot.png                          | 0.984 |  0.796  | graphics |
/// | rendered text                           | 0.990 |  0.974  | graphics |
/// | logo shapes with alpha                  | 0.991 |  0.928  | graphics |
/// | flat rectangles / linear gradient       | 0.998-1.000 | 0.972-1.000 | graphics |
///
/// Photographs top out at `run` 0.558 and `cSmooth` 0.409; graphics bottom out at 0.826 and
/// 0.510. The thresholds sit in those gaps:
///
///  * **`exactRunFraction > 0.70`** - repeated pixel values mean rendered content. Huge margin
///    (0.558 vs 0.826), and it is the net under the expensive failure, text at 4:2:0.
///  * **`coarseSmoothFraction > 0.46`** - smooth once grain is removed. Tighter, and placed at
///    the midpoint of the 0.409-0.510 gap, but it is the only thing that separates a grainy
///    render from a photograph.
///
/// Either one firing means graphics. Getting it wrong is asymmetric and the thresholds lean
/// accordingly: 4:4:4 on a photograph costs bytes, 4:2:0 on text is visible damage.
///
/// One deliberate non-goal: a crop that is nothing but featureless sky (`run` 0.753,
/// `cSmooth` 0.792) classifies as graphics. It has no chroma detail to lose either way, so the
/// decision is immaterial there, and pulling the thresholds far enough to catch it would drag
/// real photographs back with it.
///
/// ## What was measured and rejected
///
/// Hard-edge density (`edgeFraction`), palette concentration (top-32 colour share), luma
/// high-pass energy and chroma-plane spread were all measured across the same corpus. None of
/// them separates the classes: photographic grain gives real photos a *higher* edge density
/// (0.004-0.087) than rendered text (0.012), and Apple's grainy renders beat photographs on
/// luma high-pass energy (11.75 vs 4.34). `edgeFraction` is still reported because it is nearly
/// free and useful when re-tuning, but nothing branches on it.
public enum ContentAnalyzer {

    /// Native-resolution sampling: up to a 6x6 grid of 96x96 tiles, so roughly 330k pixels are
    /// examined regardless of how large the image is, with local structure intact.
    static let tileSize = 96
    static let tileGrid = 6
    /// Long edge of the grain-removing box average.
    static let coarseLongEdge = 192
    /// A coarse pixel counts as smooth when both differences stay under this (0-255 scale).
    static let coarseFlatLimit = 2.0
    static let edgeMagnitudeThreshold = 64.0

    static let runThreshold = 0.70
    static let coarseSmoothThreshold = 0.46

    public static func analyze(_ image: PixelImage) -> ContentAnalysis {
        guard image.width >= 3, image.height >= 3 else {
            return ContentAnalysis(kind: .photo, exactRunFraction: 0,
                                   coarseSmoothFraction: 0, uniqueColors: 0, edgeFraction: 0)
        }
        let fine = fineStatistics(image)
        let coarse = coarseSmoothFraction(image)

        let graphics = fine.runFraction > runThreshold || coarse > coarseSmoothThreshold
        return ContentAnalysis(kind: graphics ? .graphics : .photo,
                               exactRunFraction: fine.runFraction,
                               coarseSmoothFraction: coarse,
                               uniqueColors: fine.uniqueColors,
                               edgeFraction: fine.edgeFraction)
    }

    // MARK: - Native-resolution tiles

    /// Evenly spread tile origins. Sampling tiles rather than striding pixel-by-pixel keeps
    /// neighbours adjacent, which every one of these statistics depends on.
    static func tileOrigins(width: Int, height: Int) -> (origins: [(Int, Int)], w: Int, h: Int) {
        let w = min(tileSize, width), h = min(tileSize, height)
        let nx = max(1, min(tileGrid, width / w)), ny = max(1, min(tileGrid, height / h))
        var origins: [(Int, Int)] = []
        origins.reserveCapacity(nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let x = nx == 1 ? (width - w) / 2 : (width - w) * i / (nx - 1)
                let y = ny == 1 ? (height - h) / 2 : (height - h) * j / (ny - 1)
                origins.append((x, y))
            }
        }
        return (origins, w, h)
    }

    private static func fineStatistics(_ image: PixelImage)
        -> (runFraction: Double, uniqueColors: Int, edgeFraction: Double) {
        let (origins, tw, th) = tileOrigins(width: image.width, height: image.height)
        let bytesPerRow = image.bytesPerRow

        var seen = [Bool](repeating: false, count: 1 << 15) // 5 bits per channel, diagnostic only
        var unique = 0
        var runPairs = 0, runEqual = 0
        var edgeSamples = 0, edgeHits = 0
        let edgeLimitSquared = edgeMagnitudeThreshold * edgeMagnitudeThreshold

        image.rgba.withUnsafeBufferPointer { p in
            @inline(__always) func luma(_ x: Int, _ y: Int) -> Double {
                let o = y * bytesPerRow + x * 4
                return 0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2])
            }
            for (tx, ty) in origins {
                for y in ty..<(ty + th) {
                    let row = y * bytesPerRow
                    for x in tx..<(tx + tw) {
                        let o = row + x * 4
                        let key = (Int(p[o] >> 3) << 10) | (Int(p[o + 1] >> 3) << 5) | Int(p[o + 2] >> 3)
                        if !seen[key] { seen[key] = true; unique += 1 }
                        if x > tx {
                            let q = o - 4
                            runPairs += 1
                            if p[o] == p[q] && p[o + 1] == p[q + 1] && p[o + 2] == p[q + 2] {
                                runEqual += 1
                            }
                        }
                        if x > tx, x < tx + tw - 1, y > ty, y < ty + th - 1 {
                            let gx = luma(x + 1, y) - luma(x - 1, y)
                            let gy = luma(x, y + 1) - luma(x, y - 1)
                            edgeSamples += 1
                            if gx * gx + gy * gy > edgeLimitSquared { edgeHits += 1 }
                        }
                    }
                }
            }
        }
        return (Double(runEqual) / Double(max(1, runPairs)),
                unique,
                Double(edgeHits) / Double(max(1, edgeSamples)))
    }

    // MARK: - Coarse scale

    /// Box-averages down to `coarseLongEdge`, then reports how much of the result is locally
    /// flat in luma *and* chroma. Box averaging (rather than Lanczos) is deliberate: the point
    /// is to integrate grain away, not to produce a good-looking thumbnail.
    ///
    /// At most 8x8 source pixels are read per output pixel, so the cost is bounded no matter how
    /// large the input is - a 6016x6016 wallpaper reads the same number of samples as a 4K photo,
    /// and averaging 64 samples already cuts grain by a factor of eight.
    private static func coarseSmoothFraction(_ image: PixelImage) -> Double {
        let factor = max(1, image.longEdge / coarseLongEdge)
        let w = max(3, image.width / factor)
        let h = max(3, image.height / factor)
        guard w >= 3, h >= 3 else { return 0 }
        let step = max(1, factor / 8)
        let bytesPerRow = image.bytesPerRow

        // Planar luma / Cb / Cr at the coarse scale.
        var yPlane = [Double](repeating: 0, count: w * h)
        var cbPlane = [Double](repeating: 0, count: w * h)
        var crPlane = [Double](repeating: 0, count: w * h)

        image.rgba.withUnsafeBufferPointer { p in
            for oy in 0..<h {
                for ox in 0..<w {
                    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
                    var sy = oy * factor
                    let yEnd = min(image.height, sy + factor)
                    let xStart = ox * factor
                    let xEnd = min(image.width, xStart + factor)
                    while sy < yEnd {
                        var sx = xStart
                        let row = sy * bytesPerRow
                        while sx < xEnd {
                            let o = row + sx * 4
                            r += Double(p[o]); g += Double(p[o + 1]); b += Double(p[o + 2])
                            n += 1
                            sx += step
                        }
                        sy += step
                    }
                    guard n > 0 else { continue }
                    r /= n; g /= n; b /= n
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    let i = oy * w + ox
                    yPlane[i] = luma
                    cbPlane[i] = (b - luma) * 0.564
                    crPlane[i] = (r - luma) * 0.713
                }
            }
        }

        var smooth = 0
        var total = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let up = i - w, down = i + w, left = i - 1, right = i + 1
                let lapY = abs(4 * yPlane[i] - yPlane[left] - yPlane[right] - yPlane[up] - yPlane[down])
                let lapC = abs(4 * cbPlane[i] - cbPlane[left] - cbPlane[right] - cbPlane[up] - cbPlane[down])
                    + abs(4 * crPlane[i] - crPlane[left] - crPlane[right] - crPlane[up] - crPlane[down])
                total += 1
                if lapY < coarseFlatLimit && lapC < coarseFlatLimit { smooth += 1 }
            }
        }
        return Double(smooth) / Double(max(1, total))
    }
}
