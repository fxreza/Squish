# Squish - build contract

Native macOS image compressor. App name **Squish**, CLI binary **squish**, bundle id **com.fxreza.squish**.
Project root: `/Users/sam/Claude/Code/Squoosh`

## Hard constraints

- **Only Xcode Command Line Tools are installed** (`xcode-select -p` = /Library/Developer/CommandLineTools).
  There is **NO `xcodebuild`** and no Xcode project. Build with SwiftPM (`swift build`) only.
  The .app bundle is assembled by hand (script writes Info.plist, copies binaries, ad-hoc codesigns).
- Target: macOS 26, arm64 (Apple Silicon). Swift 6.3.
- **The shipped .app must have ZERO runtime dependencies.** Homebrew may be used at BUILD time only.
  Every helper binary is bundled inside the .app and must run on a Mac with no Homebrew.
- Never write outside the project root.

## Architecture

Decode with Apple **ImageIO** (62 input formats incl. JPEG/PNG/TIFF/PSD/HEIC/WebP/GIF/BMP/CR2/NEF/ARW).
Encode with **bundled static/relocatable helper binaries**.

```
Squish.app/Contents/
  MacOS/SquishApp            AppKit app (dock drop target, prefs, notifications)
  Resources/bin/squish       the CLI (also symlinked to /usr/local/bin by installer)
  Resources/bin/{cjpeg,jpegtran,cwebp,oxipng,pngquant,<metric>}
  Resources/lib/*.dylib      relocated deps, referenced via @executable_path/../lib
```

## The three modes

| Mode | Behaviour | Output format |
|---|---|---|
| `jpeg`  | mozjpeg, fixed quality (default 84), progressive, optimized | always .jpg |
| `webp` | cwebp, fixed quality (default 82) | always .webp |
| `vlossless` | binary-search quality to hit a perceptual metric target | **keeps input format** (JPEG->JPEG, PNG->PNG) |

`jpeg` was named `web` originally; that name is kept as a hidden, undocumented alias so
anything already installed (Quick Actions, Raycast scripts, saved app prefs) keeps working
mid-transition. Never surface `web` in `--help`, JSON output, or any UI.

- `jpeg`/`webp` accept ANY of the 62 ImageIO input formats.
- `vlossless` on PNG uses pngquant (+oxipng) driven by the same metric; on JPEG uses mozjpeg.
- Chroma: 4:2:0 default; auto-switch to 4:4:4 (`-sample 1x1`) when the image is detected as
  graphics/text (heuristic: low unique-colour count OR high proportion of hard edges).
- Metadata: stripped by default in `jpeg`/`webp`. `--keep-metadata` preserves EXIF+ICC.
  **ICC profile is always converted to sRGB on output** unless `--keep-metadata`.
- Never overwrite the input unless `--inplace` is passed explicitly.

## CLI contract (both agents code to this)

```
squish <mode> [options] <files or dirs>...

modes: jpeg | webp | vlossless

  -q, --quality N        1-100. jpeg default 84, webp default 82. Ignored by vlossless.
  -t, --target N         vlossless metric target, default 90 (higher = closer to original)
  -o, --out DIR          write results into DIR
      --suffix S         filename suffix, default "-squish"
      --inplace          overwrite the original (destructive)
      --keep-metadata    preserve EXIF + ICC
      --max-dimension N  downscale so the long edge is <= N px
      --clipboard        read image from the pasteboard, write result back to the pasteboard
  -r, --recursive        descend into directories
      --json             emit one JSON object per line on stdout
  -h, --help / --version
```

Exit 0 if every file succeeded, 1 if any failed. Human-readable progress on stderr, results on stdout.

JSON line shape:
```json
{"input":"/p/a.tif","output":"/p/a-squish.jpg","bytesIn":9123456,"bytesOut":812345,
 "savedPct":91.1,"quality":84,"score":92.4,"mode":"jpeg","ok":true,"error":null}
```

## Perceptual metric abstraction (vlossless)

Prefer **ssimulacra2** (score 0-100, higher = better; 90 = visually lossless).
Fallback **dssim** (dissimilarity, lower = better) mapped onto the same 0-100 scale.

Swift side must expose:
```swift
protocol PerceptualMetric { 
    /// 0-100, higher = more similar to the original
    func score(original: URL, candidate: URL) throws -> Double 
}
```
with `Ssimulacra2Metric` and `DssimMetric` implementations, selected at runtime by which
binary is present in `Resources/bin`. Vendor agent reports which one shipped.

Binary search: bracket quality in [55, 96], ~6 iterations, keep the SMALLEST file whose score
>= target. If even q96 misses the target, emit at q96 and set a `belowTarget` flag in JSON.

## Layout

```
Sources/SquishCore/   library: decode, encode drivers, metric, search, pipeline
Sources/squish/       CLI executable (ArgumentParser NOT allowed - no network deps; hand-roll)
Sources/SquishApp/    AppKit app executable
vendor/bin, vendor/lib  build-time output of scripts/vendor-codecs.sh
scripts/              vendor-codecs.sh, build-app.sh, install.sh
raycast/              Raycast script commands
quickactions/         Finder Quick Action
```

**No external SwiftPM dependencies.** Hand-roll argument parsing. Foundation/AppKit/ImageIO/
Accelerate/UniformTypeIdentifiers/UserNotifications only.

## Notifications

Try `UNUserNotificationCenter` from the signed bundle. If it fails (ad-hoc signing can break it),
fall back to `osascript -e 'display notification ...'`. Must degrade silently, never crash.
