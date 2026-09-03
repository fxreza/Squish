#!/bin/bash
# Installs Squish.app to /Applications, symlinks the CLI to /usr/local/bin,
# installs the Finder Quick Actions, and prints how to wire up Raycast.
#
# Safe to re-run.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Squish"
SRC_APP="$ROOT_DIR/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
CLI_LINK="/usr/local/bin/squish"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
error() { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# 1. Squish.app -> /Applications
# ---------------------------------------------------------------------------

if [ ! -d "$SRC_APP" ]; then
	error "$SRC_APP not found. Run scripts/build-app.sh first."
	exit 1
fi

info "Installing $APP_NAME.app to /Applications"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"
echo "   -> $DEST_APP"

CLI_IN_APP="$DEST_APP/Contents/Resources/bin/squish"

# ---------------------------------------------------------------------------
# 2. squish CLI -> /usr/local/bin/squish
# ---------------------------------------------------------------------------

if [ ! -x "$CLI_IN_APP" ]; then
	warn "No squish CLI found inside $APP_NAME.app - skipping the /usr/local/bin symlink."
	warn "Rebuild with scripts/build-app.sh once the squish CLI target is available, then re-run this script."
else
	info "Linking $CLI_LINK -> $CLI_IN_APP"

	NEED_SUDO=0
	if [ ! -d "/usr/local/bin" ]; then
		if mkdir -p "/usr/local/bin" 2>/dev/null; then
			:
		else
			NEED_SUDO=1
		fi
	elif [ ! -w "/usr/local/bin" ]; then
		NEED_SUDO=1
	fi

	if [ "$NEED_SUDO" -eq 1 ]; then
		echo "   /usr/local/bin needs administrator privileges to write to."
		echo "   You'll be prompted for your password to create/symlink it."
		sudo mkdir -p "/usr/local/bin"
		sudo ln -sf "$CLI_IN_APP" "$CLI_LINK"
	else
		mkdir -p "/usr/local/bin"
		ln -sf "$CLI_IN_APP" "$CLI_LINK"
	fi

	echo "   -> $CLI_LINK"
fi

# ---------------------------------------------------------------------------
# 3. Finder Quick Actions
# ---------------------------------------------------------------------------

QUICKACTIONS_INSTALL="$ROOT_DIR/quickactions/install.sh"
if [ -x "$QUICKACTIONS_INSTALL" ]; then
	info "Installing Finder Quick Actions"
	"$QUICKACTIONS_INSTALL"
else
	warn "quickactions/install.sh not found or not executable - skipping Quick Action install."
fi

# ---------------------------------------------------------------------------
# 4. Raycast
# ---------------------------------------------------------------------------

echo
info "Raycast script commands"
echo "   Squish ships five Raycast commands in: $ROOT_DIR/raycast"
echo "   To enable them: open Raycast -> Settings -> Extensions -> Script Commands"
echo "   -> Add Directory, and choose:"
echo "     $ROOT_DIR/raycast"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "==================================================================="
echo " $APP_NAME installed."
echo "   App:          $DEST_APP"
if [ -x "$CLI_IN_APP" ]; then
	echo "   CLI:          $CLI_LINK -> $(readlink "$CLI_LINK" 2>/dev/null || echo "$CLI_IN_APP")"
fi
echo "   Quick Actions: ~/Library/Services (right-click an image/folder in Finder)"
echo "   Raycast:      add $ROOT_DIR/raycast as a Script Commands directory"
echo "==================================================================="
