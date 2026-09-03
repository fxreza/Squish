#!/bin/bash
# Assembles Squish.app by hand from SwiftPM build output + vendored codec
# binaries. No Xcode/xcodebuild involved - only Command Line Tools.
#
# Usage: scripts/build-app.sh [--skip-swift-build]
#
# Idempotent: safe to re-run. Each run wipes and rebuilds Squish.app from
# scratch so stale files never linger.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Squish"
BUNDLE_ID="com.fxreza.squish"
VERSION="${SQUISH_VERSION:-1.0.4}"
BUILD_NUMBER="${SQUISH_BUILD:-5}"
MIN_SYSTEM_VERSION="26.0"

APP_DIR="$ROOT_DIR/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/.build/release"
VENDOR_BIN_DIR="$ROOT_DIR/vendor/bin"
VENDOR_LIB_DIR="$ROOT_DIR/vendor/lib"
LICENSES_SRC_DIR="$ROOT_DIR/licenses"

# Where a running copy looks for news of a newer release. The feed is a plain file
# in the repo (updates/latest.json), so publishing an update is a push, not a
# release cycle. Change these two lines if the repository ever moves.
REPOSITORY_URL="https://github.com/fxreza/Squish"
UPDATE_FEED_URL="https://raw.githubusercontent.com/fxreza/Squish/main/updates/latest.json"

SKIP_SWIFT_BUILD=0
for arg in "$@"; do
	case "$arg" in
	--skip-swift-build) SKIP_SWIFT_BUILD=1 ;;
	*)
		echo "Unknown argument: $arg" >&2
		exit 1
		;;
	esac
done

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
error() { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# 0. Licence guard.
#
# scripts/vendor-codecs.sh prefers ssimulacra2 (BSD-3-Clause) but silently falls
# back to dssim, which is AGPL-3.0-or-later. Shipping an AGPL binary inside a
# redistributed .app carries obligations far beyond the GPL ones we already
# handle for pngquant, and it would happen without anyone noticing. Refuse to
# build rather than let that ship by accident.
# ---------------------------------------------------------------------------

if [ -e "$VENDOR_BIN_DIR/dssim" ]; then
	error "vendor/bin/dssim is present. dssim is AGPL-3.0-or-later."
	error "Bundling it would impose AGPL obligations on anyone redistributing Squish.app,"
	error "including an obligation to offer complete corresponding source to network users."
	error ""
	error "Squish expects ssimulacra2 (BSD-3-Clause) as its perceptual metric. Re-run"
	error "scripts/vendor-codecs.sh so it sources ssimulacra2, then remove vendor/bin/dssim."
	error "If you genuinely intend to ship dssim, that is a deliberate licensing decision:"
	error "update ATTRIBUTION.md and licenses/ first, then remove this guard knowingly."
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. swift build -c release
# ---------------------------------------------------------------------------

if [ "$SKIP_SWIFT_BUILD" -eq 0 ]; then
	if [ ! -f "$ROOT_DIR/Package.swift" ]; then
		error "Package.swift not found at repo root. Nothing to build yet."
		exit 1
	fi
	info "swift build -c release"
	if ! swift build -c release; then
		error "swift build failed. See errors above. (SquishCore/squish are owned by another agent - if they're mid-work this is expected.)"
		exit 1
	fi
else
	info "Skipping swift build (--skip-swift-build); using existing .build/release output."
fi

APP_BINARY="$RELEASE_DIR/SquishApp"
CLI_BINARY="$RELEASE_DIR/squish"

if [ ! -x "$APP_BINARY" ]; then
	error "Missing $APP_BINARY. SquishApp didn't build - can't assemble the app bundle."
	exit 1
fi

CLI_AVAILABLE=1
if [ ! -x "$CLI_BINARY" ]; then
	warn "Missing $CLI_BINARY (squish CLI). Building Squish.app WITHOUT the CLI bundled -"
	warn "the resulting app will launch but can't compress anything until the CLI target builds."
	CLI_AVAILABLE=0
fi

# ---------------------------------------------------------------------------
# 2. Assemble the bundle tree
# ---------------------------------------------------------------------------

info "Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/bin"
mkdir -p "$APP_DIR/Contents/Resources/lib"

cp "$APP_BINARY" "$APP_DIR/Contents/MacOS/SquishApp"
chmod +x "$APP_DIR/Contents/MacOS/SquishApp"

if [ "$CLI_AVAILABLE" -eq 1 ]; then
	cp "$CLI_BINARY" "$APP_DIR/Contents/Resources/bin/squish"
	chmod +x "$APP_DIR/Contents/Resources/bin/squish"
fi

# Vendored codec binaries (cjpeg, jpegtran, cwebp, oxipng, pngquant, metric...)
if [ -d "$VENDOR_BIN_DIR" ] && [ -n "$(ls -A "$VENDOR_BIN_DIR" 2>/dev/null)" ]; then
	cp -R "$VENDOR_BIN_DIR"/. "$APP_DIR/Contents/Resources/bin/"
	chmod +x "$APP_DIR/Contents/Resources/bin/"* 2>/dev/null || true
	info "Copied $(ls -1 "$VENDOR_BIN_DIR" | wc -l | tr -d ' ') vendor binaries."
else
	warn "vendor/bin is empty - no codec binaries bundled yet (vendor-codecs.sh hasn't run / isn't owned here)."
fi

# Vendored dylibs
if [ -d "$VENDOR_LIB_DIR" ] && [ -n "$(ls -A "$VENDOR_LIB_DIR" 2>/dev/null)" ]; then
	cp -R "$VENDOR_LIB_DIR"/. "$APP_DIR/Contents/Resources/lib/"
	info "Copied $(ls -1 "$VENDOR_LIB_DIR" | wc -l | tr -d ' ') vendor dylibs."
else
	warn "vendor/lib is empty - no dylibs bundled yet."
fi

# ---------------------------------------------------------------------------
# 2b. Licence texts and third-party notices.
#
# Squish is MIT, but it redistributes third-party binaries inside the bundle.
# BSD/MIT components require their copyright notice to travel with the binary,
# and pngquant is GPL-3.0-or-later, which additionally requires the licence
# text and access to corresponding source (see ATTRIBUTION.md and
# scripts/fetch-gpl-sources.sh). Shipping these is not optional.
# ---------------------------------------------------------------------------

if [ ! -d "$LICENSES_SRC_DIR" ]; then
	error "licenses/ is missing. The bundle would redistribute third-party binaries"
	error "with no licence texts, which breaks the terms of every one of them."
	exit 1
fi

mkdir -p "$APP_DIR/Contents/Resources/licenses"
cp -R "$LICENSES_SRC_DIR"/. "$APP_DIR/Contents/Resources/licenses/"
info "Copied $(ls -1 "$LICENSES_SRC_DIR" | wc -l | tr -d ' ') licence texts."

# Report the version a bundled binary claims, or "unknown" if it will not say.
bin_version() {
	local b="$APP_DIR/Contents/Resources/bin/$1" out=""
	[ -x "$b" ] || { printf 'not bundled'; return; }
	out="$("$b" "${2:---version}" 2>&1 | head -1 | tr -d '\r')"
	[ -n "$out" ] && printf '%s' "$out" || printf 'unknown'
}

NOTICES="$APP_DIR/Contents/Resources/THIRD-PARTY-NOTICES.txt"
{
	cat <<'HDR'
Squish - third-party notices
============================

Squish itself is MIT licensed; see licenses/Squish-MIT.txt.

Squish does not link these components. It runs them as separate executables
over a command-line interface, so they are aggregated with Squish rather than
combined into it. Each remains under its own licence, reproduced in full in the
licenses/ directory inside this bundle.

IMPORTANT: pngquant is GPL-3.0-or-later. If you redistribute Squish.app you are
redistributing that binary and take on its obligations, which include providing
the corresponding source. Squish ships scripts/fetch-gpl-sources.sh, which
downloads the exact upstream source for the vendored version. See ATTRIBUTION.md.

Bundled executables
-------------------
HDR
	printf '  %-14s %-26s %s\n' "cjpeg"       "IJG AND Zlib AND BSD-3" "$(bin_version cjpeg -version)"
	printf '  %-14s %-26s %s\n' "jpegtran"    "IJG AND Zlib AND BSD-3" "$(bin_version jpegtran -version)"
	printf '  %-14s %-26s %s\n' "cwebp"       "BSD-3-Clause"           "$(bin_version cwebp -version)"
	printf '  %-14s %-26s %s\n' "oxipng"      "MIT"                    "$(bin_version oxipng)"
	printf '  %-14s %-26s %s\n' "pngquant"    "GPL-3.0-or-later"       "$(bin_version pngquant)"
	printf '  %-14s %-26s %s\n' "ssimulacra2" "BSD-3-Clause (libjxl)"  "vendored from the jpeg-xl distribution"
	cat <<'MID'

Bundled shared libraries
------------------------
  Transitive dependencies of the executables above, in Resources/lib.
  All are permissive (BSD-3-Clause, MIT, zlib, 0BSD or similar):
MID
	if [ -d "$APP_DIR/Contents/Resources/lib" ]; then
		for f in "$APP_DIR/Contents/Resources/lib"/*.dylib; do
			[ -e "$f" ] && printf '    %s\n' "$(basename "$f")"
		done
	fi
	cat <<'FTR'

Full licence texts
------------------
  Every licence referenced above is reproduced verbatim in:
      Squish.app/Contents/Resources/licenses/

  Nothing here is a summary or a paraphrase; the files are the upstream texts.
FTR
	printf '\nGenerated by scripts/build-app.sh on %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
} >"$NOTICES"
info "Wrote THIRD-PARTY-NOTICES.txt"

# ---------------------------------------------------------------------------
# 3. Fix up dylib load paths so every binary is relocatable and needs no
#    Homebrew / absolute build-machine paths at runtime.
# ---------------------------------------------------------------------------

fixup_binary_dylib_paths() {
	local binary="$1"
	[ -f "$binary" ] || return 0
	# Only ever touch Mach-O files.
	if ! file "$binary" | grep -q "Mach-O"; then
		return 0
	fi

	# Make sure @executable_path/../lib is on the rpath so @rpath-relative
	# dependencies resolve without any extra fixups.
	install_name_tool -add_rpath "@executable_path/../lib" "$binary" 2>/dev/null || true

	# Rewrite any dependency that points at a build-time absolute path
	# (Homebrew, /tmp, the vendoring machine's home dir, etc.) to
	# @executable_path/../lib/<name>, so the bundle has zero runtime
	# dependency on anything outside itself.
	otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
		case "$dep" in
		/usr/lib/* | /System/* | @executable_path/* | @rpath/* | @loader_path/*)
			# System frameworks and already-relocated paths: leave alone.
			continue
			;;
		*)
			local dep_name
			dep_name="$(basename "$dep")"
			if [ -f "$APP_DIR/Contents/Resources/lib/$dep_name" ]; then
				install_name_tool -change "$dep" "@executable_path/../lib/$dep_name" "$binary" 2>/dev/null || true
			fi
			;;
		esac
	done
}

info "Fixing up dylib load paths (relocating away from build-time absolute paths)"
for f in "$APP_DIR/Contents/Resources/bin/"*; do
	[ -f "$f" ] && fixup_binary_dylib_paths "$f"
done
for f in "$APP_DIR/Contents/Resources/lib/"*.dylib; do
	[ -f "$f" ] && fixup_binary_dylib_paths "$f"
done
fixup_binary_dylib_paths "$APP_DIR/Contents/MacOS/SquishApp"

# ---------------------------------------------------------------------------
# 4. App icon
# ---------------------------------------------------------------------------

generate_icon() {
	local out_icns="$1"
	if ! command -v magick >/dev/null 2>&1; then
		warn "magick not found - skipping icon generation. App will use the default icon."
		return 0
	fi
	if ! command -v iconutil >/dev/null 2>&1; then
		warn "iconutil not found - skipping icon generation."
		return 0
	fi

	local tmp_iconset
	tmp_iconset="$(mktemp -d)/AppIcon.iconset"
	mkdir -p "$tmp_iconset"

	# Plain, tasteful mark: a rounded-square blue tile with a downward
	# chevron nested inside a pair of brackets ("compress this down").
	local base="$tmp_iconset/base-1024.png"
	magick -size 1024x1024 xc:none \
		-fill "#2F6FED" -draw "roundrectangle 32,32 992,992 210,210" \
		-fill none -stroke white -strokewidth 56 \
		-draw "stroke-linecap round stroke-linejoin round path 'M 300,266 L 252,266 L 252,758 L 300,758'" \
		-draw "stroke-linecap round stroke-linejoin round path 'M 724,266 L 772,266 L 772,758 L 724,758'" \
		-strokewidth 68 \
		-draw "stroke-linecap round stroke-linejoin round path 'M 372,430 L 512,610 L 652,430'" \
		"$base"

	local sizes=(16 32 128 256 512)
	for size in "${sizes[@]}"; do
		magick "$base" -resize "${size}x${size}" "$tmp_iconset/icon_${size}x${size}.png"
		local double=$((size * 2))
		magick "$base" -resize "${double}x${double}" "$tmp_iconset/icon_${size}x${size}@2x.png"
	done

	iconutil -c icns "$tmp_iconset" -o "$out_icns"
	rm -rf "$(dirname "$tmp_iconset")"
}

info "Generating app icon"
generate_icon "$APP_DIR/Contents/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# 5. Info.plist
# ---------------------------------------------------------------------------

info "Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>SquishApp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_SYSTEM_VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright (c) $(date +%Y) fxreza. All rights reserved.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>SquishRepositoryURL</key>
	<string>$REPOSITORY_URL</string>
	<key>SquishUpdateFeedURL</key>
	<string>$UPDATE_FEED_URL</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Image</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.image</string>
			</array>
		</dict>
	</array>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Squish to JPEG</string>
			</dict>
			<key>NSMessage</key>
			<string>compressForWeb</string>
			<key>NSPortName</key>
			<string>$APP_NAME</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.image</string>
				<string>public.folder</string>
			</array>
			<key>NSSendTypes</key>
			<array>
				<string>NSFilenamesPboardType</string>
			</array>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Squish to WebP</string>
			</dict>
			<key>NSMessage</key>
			<string>compressToWebP</string>
			<key>NSPortName</key>
			<string>$APP_NAME</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.image</string>
				<string>public.folder</string>
			</array>
			<key>NSSendTypes</key>
			<array>
				<string>NSFilenamesPboardType</string>
			</array>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Squish to Visually Lossless</string>
			</dict>
			<key>NSMessage</key>
			<string>compressVisuallyLossless</string>
			<key>NSPortName</key>
			<string>$APP_NAME</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.image</string>
				<string>public.folder</string>
			</array>
			<key>NSSendTypes</key>
			<array>
				<string>NSFilenamesPboardType</string>
			</array>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------------------
# 6. Ad-hoc codesign, inside-out: dylibs and helper binaries first, app last.
#    (Explicit per-item signing rather than `codesign --deep`, which Apple
#    deprecated and which mishandles nested bundles unreliably.)
# ---------------------------------------------------------------------------

sign_item() {
	local path="$1"
	codesign --force --sign - --timestamp=none "$path" 2>&1 | grep -v "^$path: replacing existing signature" || true
}

info "Codesigning (ad-hoc, inside-out)"

for f in "$APP_DIR/Contents/Resources/lib/"*.dylib; do
	[ -f "$f" ] && sign_item "$f"
done

for f in "$APP_DIR/Contents/Resources/bin/"*; do
	[ -f "$f" ] && sign_item "$f"
done

sign_item "$APP_DIR/Contents/MacOS/SquishApp"
sign_item "$APP_DIR"

info "Verifying signature"
if codesign -vv "$APP_DIR" 2>&1; then
	info "Signature verified."
else
	warn "codesign -vv reported problems (see above). The app may still run locally, but this should be investigated."
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------

BIN_COUNT="$(find "$APP_DIR/Contents/Resources/bin" -type f 2>/dev/null | wc -l | tr -d ' ')"
LIB_COUNT="$(find "$APP_DIR/Contents/Resources/lib" -type f 2>/dev/null | wc -l | tr -d ' ')"
APP_SIZE="$(du -sh "$APP_DIR" 2>/dev/null | cut -f1)"

echo
echo "==================================================================="
echo " $APP_NAME.app assembled at: $APP_DIR"
echo "   version:        $VERSION ($BUILD_NUMBER)"
echo "   bundle id:      $BUNDLE_ID"
echo "   size:           $APP_SIZE"
echo "   bin/ contains:  $BIN_COUNT file(s)$([ "$CLI_AVAILABLE" -eq 0 ] && echo ' (squish CLI missing!)')"
echo "   lib/ contains:  $LIB_COUNT file(s)"
echo "   codesign:       ad-hoc, inside-out"
echo "==================================================================="
if [ "$CLI_AVAILABLE" -eq 0 ]; then
	warn "Re-run this script once the squish CLI target builds to get a fully functional app."
fi
