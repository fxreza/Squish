#!/bin/bash
# Installs the Squish Quick Actions into ~/Library/Services and refreshes
# Finder's Services cache so they show up in the right-click menu right away.
#
# Safe to re-run: each workflow is removed and recopied, not merged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$HOME/Library/Services"

WORKFLOWS=(
	"Squish to JPEG.workflow"
	"Squish to WebP.workflow"
	"Squish to Visually Lossless.workflow"
)

# Every previous name these actions have shipped under. They all began with "Compress",
# which collided with Keka's "Compress using Keka" in the same context menu - same verb,
# entirely different result (an archive, not a smaller image). Remove the old copies so
# a stale one cannot linger beside the new name.
OBSOLETE=(
	"Compress for Web.workflow"
	"Compress to JPEG.workflow"
	"Compress to WebP.workflow"
	"Compress Visually Lossless.workflow"
	"Squish Visually Lossless.workflow"
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
