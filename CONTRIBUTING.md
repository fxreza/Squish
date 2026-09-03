# Contributing to Squish

## The one hard constraint

**This project builds with Xcode Command Line Tools only - there is no Xcode project and no
`xcodebuild` anywhere in the toolchain.** Everything goes through SwiftPM (`swift build`) and
hand-written shell scripts that assemble the `.app` bundle themselves (write `Info.plist`, copy
binaries, `codesign --sign -`). Don't add a dependency, a build step, or an SPM plugin that
requires Xcode to be installed - check `xcode-select -p` if you're unsure; on the reference
development machine it points at `/Library/Developer/CommandLineTools`, not an `Xcode.app`.

Target platform is macOS 26, Apple Silicon (arm64) only, Swift 6.3.

## Project layout

```
Sources/SquishCore/   Library: ImageIO decode, encoder drivers, perceptual metric, quality
                       search, the compression pipeline. No CLI or UI code here.
Sources/squish/       The squish CLI executable. Hand-rolled argument parsing - ArgumentParser
                       is NOT allowed (it's a network dependency; see "No external
                       dependencies" below).
Sources/SquishApp/    The AppKit app. Talks to SquishCore only indirectly, by shelling out to
                       the built `squish` CLI via Process - it does not link SquishCore itself.
vendor/bin, vendor/lib
                       Build-time output of scripts/vendor-codecs.sh. Gitignored - see
                       "Vendored codecs" below.
scripts/               vendor-codecs.sh, verify-vendor.sh, build-app.sh, install.sh
raycast/               Raycast script commands (wrap the built squish CLI)
quickactions/          Finder Quick Action .workflow bundles
tests/                 tests/make-fixtures.sh generates synthetic test images;
                       tests/run-tests.sh exercises all three modes end to end
docs/                  docs/SPEC.md is the build contract - read it before touching
                       SquishCore's behavior. Everything else in docs/ is process/reference
                       material.
```

## No external SwiftPM dependencies

Foundation, AppKit, ImageIO, Accelerate, UniformTypeIdentifiers, and UserNotifications only.
This is a deliberate constraint (see `docs/SPEC.md`), not an oversight - a dependency-free build
means `swift build` never needs network access and there's no supply chain to audit beyond the
vendored codec binaries themselves (see `ATTRIBUTION.md`). If you think a feature needs a new
package dependency, that's worth discussing in an issue before you write code.

## Building

```bash
# 1. Vendor the codec binaries (mozjpeg, cwebp, oxipng, pngquant, ssimulacra2/dssim + their
#    full transitive dylib graph) into vendor/bin and vendor/lib. Needs Homebrew - it installs
#    whichever formulas are missing, then copies and relocates the binaries so the result runs
#    with zero Homebrew dependency at runtime. Safe to re-run any time.
./scripts/vendor-codecs.sh

# 2. Build the Swift package itself (SquishCore, squish CLI, SquishApp).
swift build -c release

# 3. Assemble Squish.app by hand from the swift build output + vendor/bin + vendor/lib -
#    writes Info.plist, copies binaries, fixes up dylib load paths, ad-hoc codesigns everything.
#    Safe to re-run; each run wipes and rebuilds Squish.app from scratch.
./scripts/build-app.sh
```

`scripts/build-app.sh` accepts `--skip-swift-build` if you've already run `swift build -c
release` and just want to re-assemble the bundle (e.g. after re-vendoring codecs).

Once you have a built `Squish.app`, `./scripts/install.sh` copies it to `/Applications`, symlinks
the CLI to `/usr/local/bin/squish`, and installs the Finder Quick Actions. It's optional for
day-to-day development - you can run `.build/release/squish` and `Squish.app` straight out of the
repo - but it's how you get the Quick Actions and a `squish` on your `PATH` for the Raycast
commands to find (see `raycast/README.md` for the exact lookup order those scripts use).

### Vendored codecs

`vendor/bin` and `vendor/lib` are gitignored - they're Homebrew build products, not source, and
some of them are tens to hundreds of KB of compiled binary that has no business in git history.
That means a fresh clone has an empty `vendor/`; **run `./scripts/vendor-codecs.sh` before you
build anything that needs to actually compress an image** (the Swift package itself builds fine
without it - `squish` and `SquishApp` just won't have any encoders to call).

`./scripts/verify-vendor.sh` proves the vendored tree is genuinely self-contained: it copies
`vendor/` to an isolated temp directory, checks every binary/dylib's load commands reference only
`/usr/lib`, `/System`, or `@executable_path`, confirms the ad-hoc signatures are valid, and
round-trips a synthetic test image through every tool with `PATH` stripped down to
`/usr/bin:/bin:/usr/sbin:/sbin` (no Homebrew, no `/usr/local`) so a coincidental match against
something already on your machine can't hide a real dependency. Run it after re-vendoring if
you're touching that script.

**Before you change which codec gets vendored, or add a new one, read `ATTRIBUTION.md`.**
Homebrew formulas for image codecs mix permissive (MIT/BSD) and copyleft (GPL/AGPL) licenses, and
swapping one in changes what Squish is legally allowed to ship. `pngquant` is already a
GPL-3.0-or-later binary Squish bundles - see that file for what that does and doesn't require.

## Testing

```bash
# Generates tests/fixtures/ (gitignored, synthetic images built with ImageMagick, since real
# photos don't belong in a git repo and wouldn't be reproducible anyway). Only needed once, or
# after tests/make-fixtures.sh itself changes.
./tests/make-fixtures.sh

# Builds `squish` and runs it through all three modes plus the option surface against every
# fixture, checking each output decodes, has the right container format, and is smaller than
# its input.
./tests/run-tests.sh
```

`tests/run-tests.sh` requires ImageMagick (`magick` on `PATH`) for verification and prefers
`vendor/bin` for the codec binaries, falling back to Homebrew's `mozjpeg`/`webp`/etc. if
`vendor/` hasn't been populated yet. There is no XCTest target - these are black-box, end-to-end
shell tests against the built CLI, which is what actually ships, rather than internal unit tests
against `SquishCore`.

There's no test coverage for `SquishApp`'s UI, the Finder Quick Actions, or the Raycast commands
beyond what a human running them by hand catches - keep that in mind if you're touching any of
those.

## Style

- Match the surrounding file. `scripts/*.sh` are Bash 3.2-compatible (that's what ships as
  `/bin/bash` on macOS - no associative arrays, no `mapfile`) and lean on `set -euo pipefail`
  plus small `info`/`warn`/`error`/`log`/`fail`/`ok` helper functions for output; look at an
  existing script before adding a new one.
- Swift code runs under Swift 6's strict concurrency by default (no per-target
  `swiftLanguageMode` override) - `@MainActor` isolation and `Sendable` conformance need to be
  correct, not silenced.
- `docs/SPEC.md` is the contract for `SquishCore`'s and `squish`'s observable behavior (CLI
  flags, JSON shape, mode semantics, exit codes). If a change would make actual behavior diverge
  from it, update the spec in the same change - don't let it drift.

## Opening a PR

- Run `./tests/run-tests.sh` (and `./scripts/verify-vendor.sh` if you touched vendoring) before
  opening a PR; CI runs the same scripts, so failures there will fail there too.
- Keep `CHANGELOG.md` in mind for anything user-visible - it's not required for every PR, but a
  new mode, flag, or entry point should get an entry under an `## Unreleased` heading (add one if
  it doesn't exist yet).
- See `.github/PULL_REQUEST_TEMPLATE.md` for what a description should cover.

## Reporting bugs / requesting features

Use the issue templates under `.github/ISSUE_TEMPLATE/`. For anything security-related, see
`SECURITY.md` instead of opening a public issue.
