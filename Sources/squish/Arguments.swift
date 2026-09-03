import Foundation
import SquishCore

// Kept in step with CFBundleShortVersionString in scripts/build-app.sh: the CLI and
// the app ship in the same bundle, so two different version numbers would be a lie.
let squishVersion = "1.0.1"

enum Command {
    case help
    case version
    case run(SquishOptions)
}

/// Hand-rolled parser. No SwiftPM dependencies are allowed, and the surface is small enough
/// that a table-driven parser would cost more than it saves.
///
/// Accepts `--long value`, `--long=value`, `-q value`, `-q84`, clustered boolean shorts (`-rj`)
/// and `--` to end option parsing. The mode must be the first positional token.
enum Arguments {

    static func parse(_ argv: [String]) throws -> Command {
        var mode: SquishMode?
        var quality: Int?
        var target: Double = 90
        var outDir: URL?
        var suffix = "-squish"
        var inplace = false
        var keepMetadata = false
        var maxDimension: Int?
        var clipboard = false
        var recursive = false
        var json = false
        var verify = true
        var inputs: [URL] = []

        var index = 0
        var optionsEnded = false

        func nextValue(for flag: String, inline: String?) throws -> String {
            if let inline, !inline.isEmpty { return inline }
            index += 1
            guard index < argv.count else { throw SquishError.usage("\(flag) needs a value") }
            return argv[index]
        }

        func intValue(_ raw: String, flag: String, range: ClosedRange<Int>) throws -> Int {
            guard let value = Int(raw), range.contains(value) else {
                throw SquishError.usage("\(flag) expects an integer in \(range.lowerBound)-\(range.upperBound), got '\(raw)'")
            }
            return value
        }

        while index < argv.count {
            let token = argv[index]

            if optionsEnded || token == "-" || !token.hasPrefix("-") {
                if mode == nil {
                    // "web" is a hidden alias for "jpeg", kept so nothing already installed
                    // (Quick Actions, Raycast scripts, saved app prefs) breaks mid-transition.
                    // Deliberately undocumented in --help and absent from SquishMode itself.
                    if token == "web" {
                        mode = .jpeg
                    } else if let parsed = SquishMode(rawValue: token) {
                        mode = parsed
                    } else {
                        throw SquishError.usage("unknown mode '\(token)'. Expected one of: "
                            + SquishMode.allCases.map(\.rawValue).joined(separator: ", "))
                    }
                } else {
                    inputs.append(URL(fileURLWithPath: token))
                }
                index += 1
                continue
            }

            if token == "--" { optionsEnded = true; index += 1; continue }

            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let name: String
                let inline: String?
                if let equals = body.firstIndex(of: "=") {
                    name = String(body[body.startIndex..<equals])
                    inline = String(body[body.index(after: equals)...])
                } else {
                    name = body
                    inline = nil
                }
                switch name {
                case "help": return .help
                case "version": return .version
                case "quality": quality = try intValue(try nextValue(for: "--quality", inline: inline), flag: "--quality", range: 1...100)
                case "target":
                    let raw = try nextValue(for: "--target", inline: inline)
                    guard let value = Double(raw), value >= 0, value <= 100 else {
                        throw SquishError.usage("--target expects a number in 0-100, got '\(raw)'")
                    }
                    target = value
                case "out": outDir = URL(fileURLWithPath: try nextValue(for: "--out", inline: inline))
                case "suffix": suffix = try nextValue(for: "--suffix", inline: inline)
                case "inplace": inplace = true
                case "keep-metadata": keepMetadata = true
                case "max-dimension": maxDimension = try intValue(try nextValue(for: "--max-dimension", inline: inline), flag: "--max-dimension", range: 1...100_000)
                case "clipboard": clipboard = true
                case "recursive": recursive = true
                case "json": json = true
                case "no-verify": verify = false
                default:
                    throw SquishError.usage("unknown option '--\(name)'")
                }
                index += 1
                continue
            }

            // Short flags, possibly clustered: -rj, -q84, -q 84, -o dir
            var chars = Array(token.dropFirst())
            var consumed = false
            var position = 0
            while position < chars.count {
                let flag = chars[position]
                let rest = String(chars[(position + 1)...])
                switch flag {
                case "h": return .help
                case "r": recursive = true
                case "j": json = true
                case "q":
                    quality = try intValue(try nextValue(for: "-q", inline: rest), flag: "-q", range: 1...100)
                    consumed = true
                case "t":
                    let raw = try nextValue(for: "-t", inline: rest)
                    guard let value = Double(raw), value >= 0, value <= 100 else {
                        throw SquishError.usage("-t expects a number in 0-100, got '\(raw)'")
                    }
                    target = value
                    consumed = true
                case "o":
                    outDir = URL(fileURLWithPath: try nextValue(for: "-o", inline: rest))
                    consumed = true
                default:
                    throw SquishError.usage("unknown option '-\(flag)'")
                }
                if consumed { break }
                position += 1
            }
            chars = []
            index += 1
        }

        guard let mode else {
            throw SquishError.usage("no mode given. Expected one of: "
                + SquishMode.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if inplace && outDir != nil {
            throw SquishError.usage("--inplace and --out are mutually exclusive")
        }
        if clipboard && !inputs.isEmpty {
            throw SquishError.usage("--clipboard takes no file arguments")
        }
        if !clipboard && inputs.isEmpty {
            throw SquishError.noInputs
        }
        if mode == .vlossless && quality != nil {
            FileHandle.standardError.write(Data("squish: note: vlossless ignores --quality; use --target\n".utf8))
        }

        return .run(SquishOptions(mode: mode,
                                  quality: quality,
                                  target: target,
                                  outDir: outDir,
                                  suffix: suffix,
                                  inplace: inplace,
                                  keepMetadata: keepMetadata,
                                  maxDimension: maxDimension,
                                  clipboard: clipboard,
                                  recursive: recursive,
                                  json: json,
                                  verify: verify,
                                  inputs: inputs))
    }

    static let helpText = """
    squish - native macOS image compressor

    USAGE
      squish <mode> [options] <files or directories>...
      squish <mode> [options] --clipboard

    MODES
      jpeg        mozjpeg at a fixed quality (default 75), progressive and Huffman-optimised.
                  Reads any of the ~62 formats ImageIO decodes. Always writes .jpg.
      webp        cwebp at a fixed quality (default 75). Always writes .webp.
      vlossless   binary-searches the encoder quality until a perceptual metric says the result
                  is indistinguishable from the original, then keeps the smallest file that
                  passed. JPEG in -> JPEG out, PNG in -> PNG out.

    OPTIONS
      -q, --quality N      1-100. jpeg and webp default 75. Ignored by vlossless.
      -t, --target N       vlossless metric target, 0-100, default 90.
                           90 is "visually lossless"; 95 is closer to the original and bigger.
      -o, --out DIR        write results into DIR (created if missing).
          --suffix S       filename suffix, default "-squish". Use --suffix "" with --out.
          --inplace        replace the original. Destructive, and mutually exclusive with --out.
                           When the mode changes the extension the original file is removed.
          --keep-metadata  preserve EXIF and the source ICC profile. Without it, metadata is
                           stripped and the image is converted to sRGB.
          --max-dimension N  downscale so the long edge is at most N px (Lanczos).
          --clipboard      read the image from the pasteboard and write the result back to it.
      -r, --recursive      descend into directories.
      -j, --json           emit one JSON object per line on stdout.
          --no-verify      skip the perceptual score for jpeg/webp (saves one metric run per
                           file; "score" is then null). vlossless always measures.
      -h, --help           this text.
          --version        print the version.

    OUTPUT
      Results go to stdout, progress and errors to stderr. Exit status is 0 when every file
      succeeded and 1 when any failed.

      --json line shape:
      {"input":"/p/a.tif","output":"/p/a-squish.jpg","bytesIn":9123456,"bytesOut":812345,
       "savedPct":91.1,"quality":84,"score":92.4,"mode":"jpeg","ok":true,"error":null}
      vlossless lines also carry "belowTarget"; JPEG output carries "chroma".

    NOTES
      Chroma subsampling is chosen per image: 4:2:0 for photographs, 4:4:4 for screenshots,
      text, logos and smooth synthetic renders, where 4:2:0 smears coloured edges or bands
      gradients. On a photograph 4:2:0 is about 30% cheaper at the same perceived quality.
      The input is never overwritten unless --inplace is given.

    ENVIRONMENT
      SQUISH_BIN_DIR   colon-separated directories searched for the helper binaries before
                       Resources/bin, vendor/bin and PATH. Development use.
      SQUISH_DEBUG=1   trace every vlossless encode+measure round trip on stderr.

    EXAMPLES
      squish jpeg ~/Pictures/shoot -r -o ~/out
      squish webp -q 75 hero.png
      squish vlossless --target 92 *.jpg
      squish jpeg --max-dimension 2000 --json photo.heic
    """
}
