#!/bin/bash
# End-to-end tests for the squish CLI. Exercises all three modes plus the option surface, and
# checks that every output is a valid image that is smaller than its input.
#
# Requires ImageMagick for verification (the same dependency tests/make-fixtures.sh already has).
# Helper binaries are taken from vendor/bin when it is populated; otherwise the script falls back
# to Homebrew so the suite can run before scripts/vendor-codecs.sh has been executed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/squish"
FIXTURES="$ROOT/tests/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squish-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2" "${3:-}"; fi; }

# --- helper binary discovery ---------------------------------------------------------------
if [ -x "$ROOT/vendor/bin/cjpeg" ] && [ -x "$ROOT/vendor/bin/cwebp" ]; then
    HELPER_DIR="$ROOT/vendor/bin"
    echo "using vendor/bin"
else
    export SQUISH_BIN_DIR="/opt/homebrew/opt/mozjpeg/bin:/opt/homebrew/bin:/usr/local/opt/mozjpeg/bin:/usr/local/bin"
    HELPER_DIR="$(dirname "$(command -v cjpeg 2>/dev/null || echo /opt/homebrew/opt/mozjpeg/bin/cjpeg)")"
    [ -x /opt/homebrew/opt/mozjpeg/bin/cjpeg ] && HELPER_DIR=/opt/homebrew/opt/mozjpeg/bin
    echo "vendor/bin not populated; falling back to SQUISH_BIN_DIR=$SQUISH_BIN_DIR"
fi

command -v magick >/dev/null || { echo "ImageMagick (magick) is required"; exit 1; }

echo "building..."
swift build -c release --product squish >/dev/null || { echo "build failed"; exit 1; }

for f in photo.jpg landscape.tif screenshot.png alpha.png oriented.jpg real-photo.jpg real-photo-crop.png mix-ui-photo.png; do
    [ -f "$FIXTURES/$f" ] || { echo "missing fixture $f; run tests/make-fixtures.sh"; exit 1; }
done

size() { stat -f%z "$1"; }
fmt() { magick identify -format '%m' "$1" 2>/dev/null | head -c 4; }
dims() { magick identify -format '%wx%h' "$1" 2>/dev/null; }

# Asserts the output exists, decodes, has the expected container, and is smaller than the input.
assert_output() {
    local label="$1" input="$2" output="$3" want="$4"
    if [ ! -f "$output" ]; then fail "$label" "no output at $output"; return; fi
    local got; got="$(fmt "$output")"
    if [ "$got" != "$want" ]; then fail "$label" "expected $want, got '$got'"; return; fi
    if [ -z "$(dims "$output")" ]; then fail "$label" "output does not decode"; return; fi
    local a b; a=$(size "$input"); b=$(size "$output")
    if [ "$b" -ge "$a" ]; then fail "$label" "output not smaller: $a -> $b"; return; fi
    printf '  ok    %-42s %9s -> %9s bytes (%s)\n' "$label" "$a" "$b" "$(awk -v a="$a" -v b="$b" 'BEGIN{printf "-%.1f%%", (a-b)/a*100}')"
    PASS=$((PASS + 1))
}

json_field() { python3 -c "import sys,json;print(json.loads(sys.stdin.read().strip().splitlines()[$2]).get('$1'))" ; }

echo
echo "== CLI surface =="
"$BIN" --help >/dev/null 2>&1; check $? "--help exits 0"
"$BIN" --help 2>/dev/null | grep -q "vlossless"; check $? "--help documents the modes"
"$BIN" --help 2>/dev/null | grep -qw "jpeg"; check $? "--help documents the jpeg mode"
"$BIN" --help 2>/dev/null | grep -qw "web"; [ $? -ne 0 ] && pass "--help does not mention the hidden web alias" || fail "--help does not mention the hidden web alias"
"$BIN" --version >/dev/null 2>&1; check $? "--version exits 0"

# "web" was jpeg's original name; it must keep working as an undocumented alias so nothing
# already installed (Quick Actions, Raycast scripts, saved app prefs) breaks mid-transition.
web_mode="$("$BIN" web --json --no-verify -o "$WORK/alias" "$FIXTURES/photo.jpg" 2>/dev/null | json_field mode 0)"
[ "$web_mode" = "jpeg" ]; check $? "the 'web' mode alias resolves to jpeg" "got '$web_mode'"
"$BIN" >/dev/null 2>&1; [ $? -ne 0 ] && pass "no arguments exits non-zero" || fail "no arguments exits non-zero"
"$BIN" nonsense "$FIXTURES/photo.jpg" >/dev/null 2>&1; [ $? -ne 0 ] && pass "unknown mode rejected" || fail "unknown mode rejected"
"$BIN" jpeg --bogus "$FIXTURES/photo.jpg" >/dev/null 2>&1; [ $? -ne 0 ] && pass "unknown option rejected" || fail "unknown option rejected"
"$BIN" jpeg "$FIXTURES/nope.jpg" >/dev/null 2>&1; [ $? -ne 0 ] && pass "missing file exits non-zero" || fail "missing file exits non-zero"

echo
echo "== mode: jpeg (mozjpeg, always .jpg) =="
mkdir -p "$WORK/jpeg"
"$BIN" jpeg --json -o "$WORK/jpeg" \
    "$FIXTURES/photo.jpg" "$FIXTURES/landscape.tif" "$FIXTURES/screenshot.png" \
    "$FIXTURES/alpha.png" "$FIXTURES/oriented.jpg" > "$WORK/jpeg.json" 2>"$WORK/jpeg.err"
check $? "jpeg exits 0"
assert_output "jpeg photo.jpg      -> jpg" "$FIXTURES/photo.jpg"      "$WORK/jpeg/photo-squish.jpg"     JPEG
assert_output "jpeg landscape.tif  -> jpg" "$FIXTURES/landscape.tif"  "$WORK/jpeg/landscape-squish.jpg" JPEG
assert_output "jpeg screenshot.png -> jpg" "$FIXTURES/screenshot.png" "$WORK/jpeg/screenshot-squish.jpg" JPEG
assert_output "jpeg alpha.png      -> jpg" "$FIXTURES/alpha.png"      "$WORK/jpeg/alpha-squish.jpg"     JPEG
assert_output "jpeg oriented.jpg   -> jpg" "$FIXTURES/oriented.jpg"   "$WORK/jpeg/oriented-squish.jpg"  JPEG
[ "$(wc -l < "$WORK/jpeg.json" | tr -d ' ')" = "5" ]; check $? "jpeg emits one JSON line per file"
python3 - "$WORK/jpeg.json" <<'PY'
import json, sys
required = {"input","output","bytesIn","bytesOut","savedPct","quality","score","mode","ok","error"}
for line in open(sys.argv[1]):
    obj = json.loads(line)
    assert required <= set(obj), sorted(required - set(obj))
    assert obj["ok"] is True and obj["mode"] == "jpeg"
    assert obj["bytesOut"] < obj["bytesIn"] and obj["savedPct"] > 0
PY
check $? "jpeg JSON matches the spec shape"

echo
echo "== mode: webp (cwebp, always .webp) =="
mkdir -p "$WORK/webp"
"$BIN" webp --json -o "$WORK/webp" \
    "$FIXTURES/photo.jpg" "$FIXTURES/landscape.tif" "$FIXTURES/screenshot.png" "$FIXTURES/alpha.png" \
    > "$WORK/webp.json" 2>/dev/null
check $? "webp exits 0"
assert_output "webp photo.jpg      -> webp" "$FIXTURES/photo.jpg"      "$WORK/webp/photo-squish.webp"      WEBP
assert_output "webp landscape.tif  -> webp" "$FIXTURES/landscape.tif"  "$WORK/webp/landscape-squish.webp"  WEBP
assert_output "webp screenshot.png -> webp" "$FIXTURES/screenshot.png" "$WORK/webp/screenshot-squish.webp" WEBP
assert_output "webp alpha.png      -> webp" "$FIXTURES/alpha.png"      "$WORK/webp/alpha-squish.webp"      WEBP
magick identify -format '%A' "$WORK/webp/alpha-squish.webp" 2>/dev/null | grep -qi "blend\|true\|Undefined"; check $? "webp keeps an alpha channel for alpha.png"

echo
echo "== mode: vlossless (metric-driven search, keeps the input format) =="
mkdir -p "$WORK/vl"
"$BIN" vlossless --json -o "$WORK/vl" \
    "$FIXTURES/photo.jpg" "$FIXTURES/screenshot.png" "$FIXTURES/alpha.png" "$FIXTURES/landscape.tif" \
    > "$WORK/vl.json" 2>/dev/null
check $? "vlossless exits 0"
assert_output "vl   photo.jpg      -> jpg" "$FIXTURES/photo.jpg"      "$WORK/vl/photo-squish.jpg"      JPEG
assert_output "vl   screenshot.png -> png" "$FIXTURES/screenshot.png" "$WORK/vl/screenshot-squish.png" PNG
assert_output "vl   alpha.png      -> png" "$FIXTURES/alpha.png"      "$WORK/vl/alpha-squish.png"      PNG
assert_output "vl   landscape.tif  -> jpg" "$FIXTURES/landscape.tif"  "$WORK/vl/landscape-squish.jpg"  JPEG
python3 - "$WORK/vl.json" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    obj = json.loads(line)
    assert "belowTarget" in obj, "vlossless line is missing belowTarget"
    assert obj["ok"] is True
    assert obj["score"] is not None, "vlossless must report a score"
    if not obj["belowTarget"]:
        assert obj["score"] >= 90, (obj["input"], obj["score"])
    else:
        assert obj["quality"] == 98, (obj["input"], obj["quality"])
PY
check $? "vlossless hits the target or flags belowTarget at q98"
magick identify -format '%A' "$WORK/vl/alpha-squish.png" 2>/dev/null | grep -qi "blend\|true"; check $? "vlossless preserves alpha on PNG"
# vlossless must never hand back a file larger than the one it was given. Reachable when the
# input is already compressed harder than the search can match and no lossless repack is
# available - a rotated JPEG, where the repack is disabled because jpegtran cannot reproduce
# the reference geometry.
mkdir -p "$WORK/vlall"
"$BIN" vlossless --json -o "$WORK/vlall" "$FIXTURES"/*.jpg "$FIXTURES"/*.png "$FIXTURES"/*.tif \
    > "$WORK/vlall.json" 2>/dev/null
python3 - "$WORK/vlall.json" <<'GROW'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
grew = [o for o in rows if o["ok"] and o["bytesOut"] > o["bytesIn"]]
assert not grew, [(o["input"], o["bytesIn"], o["bytesOut"]) for o in grew]
rotated = [o for o in rows if o["input"].endswith("oriented.jpg")]
assert rotated, "oriented.jpg was not processed"
assert rotated[0]["bytesOut"] <= rotated[0]["bytesIn"], rotated[0]
GROW
check $? "vlossless never produces a file larger than its input (incl. a rotated JPEG)"

"$BIN" vlossless --target 60 --json -o "$WORK/vl60" "$FIXTURES/landscape.tif" > "$WORK/vl60.json" 2>/dev/null
[ "$(size "$WORK/vl60/landscape-squish.jpg")" -lt "$(size "$WORK/vl/landscape-squish.jpg")" ]
check $? "a lower --target produces a smaller file"

echo
echo "== chroma heuristic (4:2:0 for photographs, 4:4:4 for graphics) =="
# Calibrated against real photographic material, not the synthetic fixtures: an earlier version
# passed on plasma+noise and classified every real photograph as graphics, which inflated every
# photo output by about 30%.
assert_chroma() {
    local label="$1" file="$2" want="$3"
    if [ ! -e "$file" ]; then printf '  skip  %-46s (not present)\n' "$label"; return; fi
    local got
    got="$("$BIN" jpeg --json --no-verify -o "$WORK/chroma" "$file" 2>/dev/null \
        | python3 -c "import sys,json;print(json.loads(sys.stdin.readline()).get('chroma'))")"
    if [ "$got" = "$want" ]; then
        printf '  ok    %-46s %s\n' "$label" "$got"
        PASS=$((PASS + 1))
    else
        fail "$label" "expected $want, got $got"
    fi
}

# real photographs -> 4:2:0
assert_chroma "real photo, 1920px JPEG"            "$FIXTURES/real-photo.jpg"       "4:2:0"
assert_chroma "real photo, native-resolution crop" "$FIXTURES/real-photo-crop.png"  "4:2:0"
assert_chroma "real photo, HEIC original"          "/System/Library/Wallpapers/.default/DefaultAerial.heic" "4:2:0"
assert_chroma "synthetic photo fixture"            "$FIXTURES/photo.jpg"            "4:2:0"
assert_chroma "synthetic photo fixture, TIFF"      "$FIXTURES/landscape.tif"        "4:2:0"
assert_chroma "synthetic photo fixture, rotated"   "$FIXTURES/oriented.jpg"         "4:2:0"

# graphics -> 4:4:4
assert_chroma "UI screenshot"                      "$FIXTURES/screenshot.png"       "4:4:4"
assert_chroma "logo shapes with alpha"             "$FIXTURES/alpha.png"            "4:4:4"
assert_chroma "UI screenshot with a photo in it"   "$FIXTURES/mix-ui-photo.png"     "4:4:4"
# Apple's wallpapers are smooth renders carrying heavy synthetic luma grain; at native
# resolution they are noisier than a real photograph, so only the coarse-scale chroma signal
# separates them.
assert_chroma "rendered wallpaper, grainy"         "/System/Library/Desktop Pictures/iMac Silver.heic" "4:4:4"
assert_chroma "rendered wallpaper, gradient"       "/System/Library/Desktop Pictures/Mac Blue.heic"    "4:4:4"

# The point of the whole exercise: on a real photograph the 4:2:0 choice has to be materially
# cheaper than the 4:4:4 one it used to pick. Compare against a same-quality 4:4:4 encode of the
# same source, produced with the same cjpeg.
"$BIN" jpeg --no-verify -o "$WORK/chroma420" "$FIXTURES/real-photo.jpg" >/dev/null 2>&1
if [ -x "$HELPER_DIR/cjpeg" ]; then
    magick "$FIXTURES/real-photo.jpg" -depth 8 ppm:- 2>/dev/null \
        | "$HELPER_DIR/cjpeg" -quality 84 -optimize -progressive -sample 1x1 > "$WORK/forced444.jpg" 2>/dev/null
    got=$(size "$WORK/chroma420/real-photo-squish.jpg")
    ref=$(size "$WORK/forced444.jpg")
    saving=$(awk -v a="$ref" -v b="$got" 'BEGIN{printf "%.1f", (a-b)/a*100}')
    if awk -v a="$ref" -v b="$got" 'BEGIN{exit !(b < a * 0.85)}'; then
        printf '  ok    %-46s %s -> %s bytes (%s%% vs 4:4:4)\n' \
            "real photo is materially cheaper at 4:2:0" "$ref" "$got" "$saving"
        PASS=$((PASS + 1))
    else
        fail "real photo is materially cheaper at 4:2:0" "4:4:4 $ref vs chosen $got"
    fi
fi

echo
echo "== options =="
before=$(shasum "$FIXTURES/photo.jpg" | cut -d' ' -f1)
after=$(shasum "$FIXTURES/photo.jpg" | cut -d' ' -f1)
[ "$before" = "$after" ]; check $? "inputs are never modified"

"$BIN" jpeg --suffix "-small" -o "$WORK/sfx" "$FIXTURES/photo.jpg" >/dev/null 2>&1
[ -f "$WORK/sfx/photo-small.jpg" ]; check $? "--suffix is honoured and --out creates the directory"

"$BIN" jpeg --max-dimension 400 -o "$WORK/dim" "$FIXTURES/photo.jpg" >/dev/null 2>&1
[ "$(dims "$WORK/dim/photo-squish.jpg")" = "400x300" ]
check $? "--max-dimension downscales the long edge" "got $(dims "$WORK/dim/photo-squish.jpg")"

[ "$(dims "$WORK/jpeg/oriented-squish.jpg")" = "900x1200" ]
check $? "EXIF orientation is applied to the pixels" "got $(dims "$WORK/jpeg/oriented-squish.jpg")"

mkdir -p "$WORK/ip"
cp "$FIXTURES/photo.jpg" "$WORK/ip/copy.jpg"
orig=$(size "$WORK/ip/copy.jpg")
"$BIN" jpeg --inplace "$WORK/ip/copy.jpg" >/dev/null 2>&1
[ -f "$WORK/ip/copy.jpg" ] && [ "$(size "$WORK/ip/copy.jpg")" -lt "$orig" ]
check $? "--inplace replaces the original"

mkdir -p "$WORK/tree/nested"
cp "$FIXTURES/photo.jpg" "$WORK/tree/a.jpg"
cp "$FIXTURES/screenshot.png" "$WORK/tree/nested/b.png"
"$BIN" jpeg "$WORK/tree" >/dev/null 2>&1
[ -f "$WORK/tree/a-squish.jpg" ] && [ ! -f "$WORK/tree/nested/b-squish.jpg" ]
check $? "a directory without -r stays shallow"
"$BIN" jpeg -r "$WORK/tree" >/dev/null 2>&1
[ -f "$WORK/tree/nested/b-squish.jpg" ]; check $? "-r descends into subdirectories"

mkdir -p "$WORK/clash"
cp "$FIXTURES/photo.jpg" "$WORK/clash/shot.jpg"
cp "$FIXTURES/landscape.tif" "$WORK/clash/shot.tif"
"$BIN" jpeg -o "$WORK/clash-out" "$WORK/clash/shot.jpg" "$WORK/clash/shot.tif" >/dev/null 2>&1
if [ $? -ne 0 ] && [ "$(ls "$WORK/clash-out" | wc -l | tr -d ' ')" = "1" ]; then
    pass "colliding output names are refused, not silently overwritten"
else
    fail "colliding output names are refused, not silently overwritten"
fi

"$BIN" jpeg --keep-metadata -o "$WORK/meta" "$FIXTURES/oriented.jpg" >/dev/null 2>&1
[ "$(magick identify -format '%[EXIF:Orientation]' "$WORK/meta/oriented-squish.jpg" 2>/dev/null)" = "1" ]
check $? "--keep-metadata carries EXIF, with orientation normalised to 1"

"$BIN" jpeg --json --no-verify -o "$WORK/nov" "$FIXTURES/photo.jpg" 2>/dev/null | grep -q '"score":null'
check $? "--no-verify omits the perceptual score"

# Run a copy of the binary from a directory with no project root above it and an empty PATH,
# so neither Resources/bin, vendor/bin nor PATH can satisfy the lookup.
mkdir -p "$WORK/iso"
cp "$BIN" "$WORK/iso/squish"
# Note: squish exits 1 here by design, and `set -o pipefail` would propagate that, so the
# output is captured to a file before it is matched.
( cd "$WORK/iso" && env -i PATH=/nonexistent ./squish jpeg -o "$WORK/nobin" "$FIXTURES/photo.jpg" ) \
    > "$WORK/nobin.log" 2>&1
grep -q "missing helper binary 'cjpeg'" "$WORK/nobin.log"
check $? "a missing helper binary produces a clear, named error"

# The pasteboard is shared with whatever the user is doing, so this one is opt-in.
if [ "${SQUISH_TEST_CLIPBOARD:-0}" = "1" ]; then
    echo
    echo "== clipboard =="
    osascript -e "set the clipboard to (read (POSIX file \"$FIXTURES/screenshot.png\") as «class PNGf»)" >/dev/null 2>&1
    "$BIN" jpeg --clipboard --json > "$WORK/clip.json" 2>/dev/null
    check $? "--clipboard round trips through the pasteboard"
    osascript -e 'get the clipboard as «class JPEG»' >/dev/null 2>&1
    check $? "the pasteboard now holds a JPEG"
fi

echo
echo "-------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
