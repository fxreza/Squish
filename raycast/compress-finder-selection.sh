#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Compress Finder Selection
# @raycast.mode compact
# @raycast.icon 🗜️
# @raycast.packageName Squish

set -euo pipefail

# Locates the squish binary. Inlined rather than sourced from a shared lib/ file: Raycast
# users copy individual .sh files into their own script-commands directory, so each command
# must work completely standalone with no sibling files.
# Order: $SQUISH_BIN -> `command -v squish` -> /usr/local/bin/squish ->
# /Applications/Squish.app/... -> $HOME/Applications/Squish.app/...
locate_squish() {
  if [ -n "${SQUISH_BIN:-}" ] && [ -x "${SQUISH_BIN:-}" ]; then
    echo "$SQUISH_BIN"
    return 0
  fi

  local on_path
  on_path="$(command -v squish 2>/dev/null || true)"
  if [ -n "$on_path" ] && [ -x "$on_path" ]; then
    echo "$on_path"
    return 0
  fi

  local candidates=(
    "/usr/local/bin/squish"
    "/Applications/Squish.app/Contents/Resources/bin/squish"
    "$HOME/Applications/Squish.app/Contents/Resources/bin/squish"
  )
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done

  return 1
}

SQUISH="$(locate_squish)" || {
  echo "squish not found. Install Squish.app or run scripts/install.sh (or set \$SQUISH_BIN)."
  exit 1
}

# Squish.app writes its default mode into the com.fxreza.squish prefs suite
# (see Sources/SquishApp/Preferences.swift). Fall back to "jpeg" if unset.
MODE="$(defaults read com.fxreza.squish defaultMode 2>/dev/null || true)"
if [ -z "$MODE" ]; then
  MODE="jpeg"
fi

SELECTION="$(osascript <<'APPLESCRIPT'
tell application "Finder"
	set selectedItems to selection
	set out to ""
	repeat with anItem in selectedItems
		set out to out & (POSIX path of (anItem as alias)) & linefeed
	end repeat
	return out
end tell
APPLESCRIPT
)"

if [ -z "$SELECTION" ]; then
  echo "No Finder selection found."
  exit 1
fi

# Build an array of paths from the newline-separated AppleScript output.
PATHS=()
while IFS= read -r line; do
  [ -n "$line" ] && PATHS+=("$line")
done <<< "$SELECTION"

if [ "${#PATHS[@]}" -eq 0 ]; then
  echo "No Finder selection found."
  exit 1
fi

OUTPUT="$("$SQUISH" "$MODE" -r --json "${PATHS[@]}" 2>/dev/null)" || {
  echo "Compression failed for one or more items."
}

echo "$OUTPUT" | /usr/bin/python3 - "$MODE" <<'PY'
import json, sys

mode = sys.argv[1]
lines = sys.stdin.read().strip().splitlines()

count = 0
bytes_in = 0
bytes_out = 0
failed = 0

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    count += 1
    if r.get("ok"):
        bytes_in += r.get("bytesIn") or 0
        bytes_out += r.get("bytesOut") or 0
    else:
        failed += 1

def human(n):
    n = float(n)
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} {unit}"
        n /= 1024

if count == 0:
    print(f"No files compressed ({mode}).")
else:
    pct = (1 - bytes_out / bytes_in) * 100 if bytes_in else 0
    fail_note = f", {failed} failed" if failed else ""
    print(f"{count} item(s) ({mode}) · {human(bytes_in)} → {human(bytes_out)} · saved {pct:.0f}%{fail_note}")
PY
