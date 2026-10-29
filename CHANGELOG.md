# Changelog

All notable changes to Squish are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## 1.0.5

### Changed

- **The real app icon.** The bundle now carries Squish's designed icon instead of the placeholder
  that was drawn at build time.

### Fixed

- **Panning the comparison view vertically went the wrong way.** Dragging or two-finger scrolling
  upwards moved the image down, and the other way round; left and right were already correct. The
  image now follows the hand on both axes, and a drag is measured from the cursor position rather
  than from `NSEvent`'s mouse deltas, so it cannot depend on which frame AppKit reports those in.
- **`scripts/build-app.sh` could not finish a build.** It read the vendored codec versions by
  running them from inside the half-assembled bundle. Once macOS had seen code execute in there it
  protected the bundle, so writing `THIRD-PARTY-NOTICES.txt` failed with an I/O error and the
  build aborted before the dylib fixups and the signing. The versions now come from `vendor/bin`.

## 1.0.0

Initial release.

### Added

- **Three compression modes.**
  - `jpeg` (accepts the legacy `web` token too) - mozjpeg at a fixed quality (default 84),
    progressive, optimized. Always outputs `.jpg`.
  - `webp` - cwebp at a fixed quality (default 82). Always outputs `.webp`.
  - `vlossless` - binary-searches quality (bracketed in [55, 96], ~6 iterations) to find the
    smallest file whose perceptual similarity score meets a target (default 90/100), keeping the
    input's own format: JPEG stays JPEG (mozjpeg), PNG stays PNG (pngquant + oxipng). If even the
    top of the quality bracket misses the target, Squish still emits that file and flags it
    `belowTarget` in JSON output rather than failing outright.
  - All three modes decode through Apple ImageIO, so any of its ~62 supported input formats (JPEG,
    PNG, TIFF, PSD, HEIC, WebP, GIF, BMP, CR2, NEF, ARW, and more) can go in, regardless of mode.
- **Perceptual metric abstraction.** `vlossless` scores candidates with ssimulacra2 when it's
  available at build time, falling back to dssim on the same 0-100 scale otherwise - selected once
  at vendoring time (`scripts/vendor-codecs.sh`), not per-run.
- **Chroma subsampling heuristic.** Defaults to 4:2:0; auto-switches to 4:4:4 for images detected
  as graphics/text (low unique-colour count or a high proportion of hard edges), where 4:2:0's
  color-plane blur is most visible.
- **Metadata handling.** EXIF and ICC are stripped by default in `jpeg`/`webp` mode, with the ICC
  profile converted to sRGB on output; `--keep-metadata` preserves both instead. Input files are
  never overwritten unless `--inplace` is passed explicitly.
- **`squish` CLI** - hand-rolled argument parsing (no external dependencies): quality/target
  overrides, `--out`, `--suffix`, `--inplace`, `--keep-metadata`, `--max-dimension`, `--clipboard`
  (read/write the pasteboard instead of files), `-r`/`--recursive`, and `--json` for one JSON
  object per line on stdout. Exit code is 0 only if every input file succeeded.
- **Squish.app** - an AppKit dock app: drag-and-drop compression, a preferences window for
  per-mode defaults, and native notifications (falling back to `osascript -e 'display
  notification'` if `UNUserNotificationCenter` doesn't work under ad-hoc signing). Shells out to
  the bundled `squish` CLI rather than linking against `SquishCore` directly.
- **Finder Quick Actions** - right-click compression workflows for JPEG, WebP, and visually
  lossless modes, installed into `~/Library/Services`.
- **Raycast script commands** - compress the clipboard image, the frontmost Finder selection, or
  the most recent screenshot, in any of the three modes, without leaving the keyboard.
- **Zero runtime dependencies.** Every encoder (mozjpeg, cwebp, oxipng, pngquant, the perceptual
  metric binary) and their full transitive dylib graph are vendored into
  `Squish.app/Contents/Resources/{bin,lib}` at build time and relocated to
  `@executable_path/../lib`, so the shipped app needs no Homebrew (or anything else) installed on
  the machine that runs it. Homebrew is a build-time-only dependency, used by
  `scripts/vendor-codecs.sh`.

### Known limitations

- `Squish.app` is currently **ad-hoc signed only** - no Developer ID, no notarization. See
  `RELEASE.md` for what that means for anyone downloading a built copy.
- `pngquant`, which `vlossless` mode relies on for PNG input, is GPL-3.0-or-later licensed. See
  `ATTRIBUTION.md` for what that means for redistributing `Squish.app`.
