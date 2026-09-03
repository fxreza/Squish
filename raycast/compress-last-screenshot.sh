#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Compress Last Screenshot
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

# Screenshots go to ~/Desktop by default, or wherever `defaults read
# com.apple.screencapture location` points if the user has changed it.
SCREENSHOT_DIR="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
if [ -z "$SCREENSHOT_DIR" ]; then
  SCREENSHOT_DIR="$HOME/Desktop"
fi
SCREENSHOT_DIR="${SCREENSHOT_DIR/#\~/$HOME}"

LATEST="$(find "$SCREENSHOT_DIR" -maxdepth 1 \( -iname "Screenshot*.png" -o -iname "Screen Shot*.png" \) 2>/dev/null \
  | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
  | sort -rn \
  | head -n 1 \
  | cut -d' ' -f2-)"

if [ -z "$LATEST" ]; then
  echo "No screenshots found in $SCREENSHOT_DIR."
  exit 1
fi

MODE="$(defaults read com.fxreza.squish defaultMode 2>/dev/null || true)"
if [ -z "$MODE" ]; then
  MODE="jpeg"
fi

OUTPUT="$("$SQUISH" "$MODE" --json "$LATEST" 2>/dev/null)" || {
  echo "Compression failed for $(basename "$LATEST")."
  exit 1
}

LAST_LINE="$(echo "$OUTPUT" | tail -n 1)"

/usr/bin/python3 - "$LAST_LINE" <<'PY'
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print("Compressed, but couldn't parse the result.")
    sys.exit(0)

if not r.get("ok", False):
    print(f"Failed: {r.get('error') or 'unknown error'}")
    sys.exit(1)

bin_ = r.get("bytesIn") or 0
bout = r.get("bytesOut") or 0
pct = r.get("savedPct")
name = r.get("input", "").split("/")[-1]

def human(n):
    n = float(n)
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} {unit}"
        n /= 1024

pct_str = f"{pct:.0f}%" if pct is not None else "?"
print(f"{name} · {human(bin_)} → {human(bout)} · saved {pct_str}")
PY
