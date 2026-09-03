#!/bin/bash
# Installs the Squish Quick Actions into ~/Library/Services and refreshes
# Finder's Services cache so they show up in the right-click menu right away.
#
# Safe to re-run: each workflow is removed and recopied, not merged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$HOME/Library/Services"

WORKFLOWS=(
	"Compress to JPEG.workflow"
	"Compress to WebP.workflow"
	"Compress Visually Lossless.workflow"
)

# Renamed from "Compress for Web.workflow" when the jpeg mode was renamed from "web". Remove
# the old name so a stale, broken copy doesn't linger in the Services menu next to the new one.
OBSOLETE=(
	"Compress for Web.workflow"
)

mkdir -p "$SERVICES_DIR"

for wf in "${OBSOLETE[@]}"; do
	old="$SERVICES_DIR/$wf"
	if [ -d "$old" ]; then
		rm -rf "$old"
		echo "Removed obsolete: $old"
	fi
done

for wf in "${WORKFLOWS[@]}"; do
	src="$SCRIPT_DIR/$wf"
	dst="$SERVICES_DIR/$wf"
	if [ ! -d "$src" ]; then
		echo "Missing $src - skipping." >&2
		continue
	fi
	rm -rf "$dst"
	cp -R "$src" "$dst"
	echo "Installed: $dst"
done

# Refresh the Services menu so Finder picks up the new/updated Quick Actions
# without requiring a logout.
/System/Library/CoreServices/pbs -flush

echo
echo "Done. Right-click an image or folder in Finder -> Quick Actions to find them."
echo "If they don't show up immediately, log out and back in, or check"
echo "System Settings -> Keyboard -> Keyboard Shortcuts -> Services."
