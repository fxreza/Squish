#!/bin/bash
# Packages Squish.app into a distributable disk image.
#
# Usage: scripts/build-dmg.sh [--skip-app-build]
#
# A .dmg rather than a .zip because it is what macOS users expect from a download:
# it mounts to a window holding the app beside an Applications alias, so installing
# is one drag. A zip drops a bare .app wherever the browser put it, and people end
# up running Squish out of ~/Downloads without realising.
#
# Idempotent: safe to re-run, always rebuilds from scratch.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Squish"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
error() { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; }

SKIP_APP_BUILD=0
for arg in "$@"; do
	case "$arg" in
	--skip-app-build) SKIP_APP_BUILD=1 ;;
	*) echo "Unknown argument: $arg" >&2; exit 1 ;;
	esac
done

if [ "$SKIP_APP_BUILD" -eq 0 ]; then
	info "Building $APP_NAME.app"
	"$ROOT_DIR/scripts/build-app.sh" >/dev/null
fi

if [ ! -d "$APP_DIR" ]; then
	error "$APP_DIR not found. Run scripts/build-app.sh first."
	exit 1
fi

# Version comes from the bundle, so the dmg can never disagree with what is inside it.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Stage in a temp dir: the dmg contains exactly the app and an Applications alias,
# nothing stray from the working tree.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "Staging"
cp -R "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# A .DS_Store would fix icon positions, but writing one requires scripting Finder on a
# mounted volume, which needs an interactive session and Finder automation permission.
# A plain window is honest and works everywhere; the Applications alias is what makes
# the drag obvious.

info "Creating disk image"
hdiutil create \
	-volname "$APP_NAME $VERSION" \
	-srcfolder "$STAGE" \
	-ov \
	-format UDZO \
	-imagekey zlib-level=9 \
	"$DMG_PATH" >/dev/null

if [ ! -f "$DMG_PATH" ]; then
	error "hdiutil reported success but $DMG_PATH is missing."
	exit 1
fi

# Ad-hoc sign the image itself. It is not notarised - see RELEASE.md - but a signed
# image at least carries an identity, and signing here is free.
codesign --force --sign - "$DMG_PATH" 2>/dev/null || warn "Could not sign the disk image (continuing)."

info "Verifying the image mounts and contains a working app"
MOUNT_DIR="$(mktemp -d)"
if hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet; then
	if [ -d "$MOUNT_DIR/$APP_NAME.app" ]; then
		if codesign -vv "$MOUNT_DIR/$APP_NAME.app" >/dev/null 2>&1; then
			info "Signature valid inside the image."
		else
			warn "The app inside the image does not verify."
		fi
		# The whole point of the bundle is that it needs nothing installed. Prove it
		# from the read-only image, with Homebrew stripped out of the environment.
		if env -i PATH=/usr/bin:/bin HOME="$MOUNT_DIR" \
			"$MOUNT_DIR/$APP_NAME.app/Contents/Resources/bin/squish" --version >/dev/null 2>&1; then
			info "CLI runs from the image with no Homebrew on PATH."
		else
			warn "The bundled CLI did not run from the mounted image."
		fi
	else
		warn "$APP_NAME.app is missing from the mounted image."
	fi
	hdiutil detach "$MOUNT_DIR" -quiet || true
else
	warn "Could not mount the image to verify it."
fi
rmdir "$MOUNT_DIR" 2>/dev/null || true

SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo
echo "==================================================================="
printf " %s %s\n" "$APP_NAME" "$VERSION"
printf "   image:   %s\n" "$DMG_PATH"
printf "   size:    %s\n" "$SIZE"
printf "   signing: ad-hoc (not notarised - first launch needs right-click > Open)\n"
echo "==================================================================="
