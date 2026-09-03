# Squish Release Workflow Guide

This describes how to cut a Squish release and what "distribution" currently means for it. Read
the **Signing and Gatekeeper** section before telling anyone outside your own Mac to download a
build - it changes what "release" can honestly mean right now.

There is no `scripts/release.sh` yet - unlike some other projects, this one doesn't have a single
command that does the whole thing. Everything below chains together scripts that already exist
(`vendor-codecs.sh`, `build-app.sh`, `verify-vendor.sh`, `run-tests.sh`) plus a few manual steps.
If you find yourself doing this more than a couple of times, scripting steps 2-5 into one file is
a reasonable thing to contribute.

---

## Prerequisites

- You're on `main` with a clean working tree.
- `CHANGELOG.md` has a section for the version you're about to release, following the format of
  the `1.0.0` entry.
- Xcode Command Line Tools only - no Xcode, no `xcodebuild` (see `CONTRIBUTING.md`). Everything
  below is `swift build` and hand-written shell scripts.

## Step 1: Decide the version

Squish's version isn't stored in a checked-in file the way `Info.plist` usually holds it - it's
passed to `scripts/build-app.sh` via environment variables at build time:

```bash
export SQUISH_VERSION=1.1.0   # CFBundleShortVersionString - default is 1.0.0
export SQUISH_BUILD=2         # CFBundleVersion - increment per build, default is 1
```

Pick these before Step 3, and use the same `SQUISH_VERSION` for the git tag in Step 5 and the
`CHANGELOG.md` heading from the prerequisites above, so all three agree.

## Step 2: Vendor codecs and build the Swift package

```bash
./scripts/vendor-codecs.sh   # populates vendor/bin + vendor/lib from Homebrew
swift build -c release
```

`vendor-codecs.sh` prints which perceptual-metric binary it shipped
(`ssimulacra2` or `dssim`). **Confirm it says `ssimulacra2`.** If it says `dssim`, stop - that
binary is AGPL-3.0-or-later, a materially different license situation than the BSD-3-Clause
`ssimulacra2` binary. See `ATTRIBUTION.md`'s "dssim" section before releasing a build that
bundles it.

## Step 3: Verify the vendored tree, then run the tests

```bash
./scripts/verify-vendor.sh   # proves vendor/ has zero Homebrew/absolute-path dependencies
./tests/make-fixtures.sh     # only needed once, or after the fixture generator itself changes
./tests/run-tests.sh
```

Don't skip `verify-vendor.sh` for a release build specifically - a binary that happens to work on
your machine because Homebrew is installed, but that would fail on a clean Mac, is exactly the
kind of bug this script exists to catch before it reaches someone else's machine.

## Step 4: Assemble the app

```bash
./scripts/build-app.sh
```

This writes `Squish.app` at the repo root: copies the built `SquishApp` and `squish` binaries,
copies `vendor/bin` and `vendor/lib` into `Contents/Resources/{bin,lib}`, fixes up dylib load
paths so nothing points at a build-time absolute path, generates an app icon (needs ImageMagick's
`magick` - the script warns and skips this step if it's missing rather than failing the build),
and **ad-hoc codesigns everything** (`codesign --force --sign -`).

Sanity-check the result before packaging it:

```bash
open Squish.app
.build/release/squish --version
```

## Step 5: Package, tag, and publish

```bash
VERSION="$SQUISH_VERSION"   # e.g. 1.1.0
ZIP="Squish_${VERSION}.zip"
ditto -c -k --keepParent Squish.app "$ZIP"
shasum -a 256 "$ZIP" > checksums.txt

git tag "v$VERSION"
git push origin main "v$VERSION"

gh release create "v$VERSION" \
  "$ZIP" checksums.txt \
  --title "Squish v$VERSION" \
  --notes "See CHANGELOG.md for details."
```

Nothing here uploads anywhere automatically - `gh release create` is the point at which a build
becomes something other people can download. Everything before it is local.

---

## Signing and Gatekeeper

**`Squish.app` is ad-hoc signed only** (`codesign --force --sign -` in `scripts/build-app.sh`,
`scripts/vendor-codecs.sh` does the same for the vendored binaries individually). Ad-hoc signing
satisfies macOS's requirement that arm64 binaries be signed at all - it's not optional, code
built and modified via `install_name_tool` would refuse to run otherwise - but it is **not** the
same as a Developer ID signature, and there is no notarization step anywhere in this pipeline.

What that means in practice:

- **On the machine that built it**, `open Squish.app` or double-clicking it in Finder works fine
  - Gatekeeper doesn't second-guess a binary you just built locally in the same session.
- **On any other Mac**, downloading `Squish.app` (or a zip containing it) and double-clicking it
  will show Gatekeeper's "cannot be opened because the developer cannot be verified" dialog, or
  on older macOS versions, an outright "is damaged and can't be opened" message (a known, widely
  reported Gatekeeper quirk for ad-hoc-signed apps downloaded via a browser, which sets the
  `com.apple.quarantine` extended attribute). The workaround for anyone you send a build to:
  **right-click the app → Open → Open**, which bypasses the Gatekeeper prompt for that one launch
  and doesn't require disabling Gatekeeper system-wide. `xattr -cr Squish.app` also works if
  they're comfortable with Terminal.
- This is a real distribution UX cost, not a cosmetic warning - most people who hit the "damaged"
  dialog assume the download failed and give up rather than right-click. If you want Squish to be
  downloadable and double-click-openable without a workaround, ad-hoc signing isn't enough.

### What proper distribution would need

1. **An Apple Developer Program membership** ($99/year) to get a Developer ID Application
   certificate.
2. **Sign with that identity** instead of `--sign -`:
   `codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" Squish.app`
   (and every vendored binary/dylib needs to already carry a valid signature under that same
   identity or be re-signed the same way - ad-hoc-signing them individually first, as
   `vendor-codecs.sh` currently does, then re-signing the assembled bundle with a real identity,
   generally works, but verify with `codesign -vvv --deep --strict Squish.app` before shipping).
3. **Notarize** the signed app or zip with `xcrun notarytool submit ... --wait`, then staple the
   ticket with `xcrun stapler staple Squish.app`. Notarization needs an app-specific password or
   API key from Apple, generally supplied via environment variables or a keychain profile rather
   than committed anywhere.
4. **Hardened runtime + entitlements** - Developer ID distribution requires the hardened runtime
   to be enabled (`--options runtime` to `codesign`), which may need explicit entitlements for
   anything Squish does that the hardened runtime restricts by default (check this against what
   `SquishApp` actually needs - notifications, pasteboard access, file access outside the
   sandbox-equivalent default reach).

None of that is implemented in `scripts/build-app.sh` today, and doing it requires an Apple
Developer account this repository's automation can't provision for you. Until someone with that
account wires it in, every release from this workflow is ad-hoc-signed, and every recipient other
than the machine that built it needs the right-click-Open workaround above. Say so plainly in
release notes rather than letting people discover it via a "damaged" dialog.

---

## Tag Format

`vX.Y.Z` (e.g. `v1.1.0`), matching the `SQUISH_VERSION` used to build it and the `CHANGELOG.md`
heading.
