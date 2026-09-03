#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Squish Clipboard to Visually Lossless
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

OUTPUT="$("$SQUISH" vlossless --clipboard --json 2>/dev/null)" || {
  echo "Compression failed. Is there an image on the clipboard?"
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

bout = r.get("bytesOut") or 0
score = r.get("score")
below = r.get("belowTarget")

def human(n):
    n = float(n)
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} {unit}"
        n /= 1024

score_str = f", score {score:.0f}" if score is not None else ""
flag = " (below target)" if below else ""
print(f"Compressed → {human(bout)}  (vlossless{score_str}){flag}")
PY
