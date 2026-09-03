# Squish

A native macOS image compressor. Decodes anything ImageIO can read (JPEG, PNG, TIFF, PSD, HEIC,
WebP, GIF, BMP, CR2, NEF, ARW, and more) and re-encodes it with bundled codec binaries. No
runtime dependencies - everything Squish needs ships inside the app.

## The three modes

| Mode | What it does | Output | Use it when |
|---|---|---|---|
| `jpeg` | mozjpeg at a fixed quality (default 84), progressive, optimized | always `.jpg` | You want small, predictable JPEGs for a website, client gallery, or messaging - the default choice. |
| `webp` | cwebp at a fixed quality (default 82) | always `.webp` | You control the delivery format and want WebP's better compression. |
| `vlossless` | binary-searches quality to hit a perceptual-similarity target (default 90/100) | keeps the input format (JPEG stays JPEG, PNG stays PNG) | You want the smallest file that's still visually indistinguishable from the original - screenshots, design assets, anything you'd otherwise hesitate to compress. |

All three strip EXIF and convert the ICC profile to sRGB by default; `--keep-metadata`
preserves both. Squish never overwrites your original unless you pass `--inplace`.

## Install

```
scripts/build-app.sh    # assembles Squish.app (swift build -c release + bundling + codesign)
scripts/install.sh      # copies it to /Applications, symlinks the CLI, installs Quick Actions
```

`scripts/install.sh` also prints how to point Raycast at `raycast/`. Both scripts are safe to
re-run.

## CLI usage

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

Examples:

```
squish jpeg photo.jpg                       # photo-squish.jpg, quality 84
squish webp -q 90 ./exports -r              # every image under ./exports, recursively, as WebP
squish vlossless -t 95 screenshot.png       # smallest PNG that's ~indistinguishable at target 95
squish jpeg --clipboard                     # compress whatever image is on the clipboard
squish jpeg --inplace --keep-metadata a.jpg # overwrite a.jpg in place, keep EXIF/ICC
```

Exit code is 0 if every file succeeded, 1 if any failed. Progress goes to stderr, results to
stdout (one JSON object per line with `--json`).

## The three entry points

1. **Squish.app** - drop files or folders on the Dock icon, or "Open With" -> Squish. Cmd+O
   opens a file picker; the window also accepts drops directly. Runs silently and posts a
   completion notification ("12 images - 84.3 MB -> 9.1 MB - saved 89%"). Preferences (Cmd+,)
   set the default mode, quality/target, output behavior, metadata, and max dimension - the app
   just drives the CLI with your saved flags.

2. **Finder Quick Actions** (`quickactions/`) - right-click an image or folder in Finder ->
   Quick Actions -> "Compress to JPEG" / "Compress to WebP" / "Compress Visually Lossless".
   Installed by `quickactions/install.sh` into `~/Library/Services`.

3. **Raycast** (`raycast/`) - five script commands: compress the clipboard image (in each of the
   three modes), compress the current Finder selection, or compress the newest screenshot. Add
   `raycast/` as a Script Commands directory in Raycast's settings. See `raycast/README.md`.

## Layout

```
Sources/SquishCore/   library: decode, encode drivers, metric, search, pipeline
Sources/squish/       CLI executable
Sources/SquishApp/    AppKit app
vendor/bin, vendor/lib  vendored codec binaries + dylibs (scripts/vendor-codecs.sh)
scripts/              vendor-codecs.sh, build-app.sh, install.sh
raycast/              Raycast script commands
quickactions/         Finder Quick Action workflows
```
