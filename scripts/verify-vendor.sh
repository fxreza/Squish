#!/bin/bash
# verify-vendor.sh — prove that vendor/bin + vendor/lib are truly relocatable:
# no Homebrew dependency at runtime, no non-system/non-@executable_path load
# commands, and every tool actually works end to end on a real image.
#
# Bash 3.2 compatible.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_BIN="$ROOT/vendor/bin"
VENDOR_LIB="$ROOT/vendor/lib"

log()  { printf '[verify-vendor] %s\n' "$*" >&2; }
fail() { printf '[verify-vendor] FAIL: %s\n' "$*" >&2; FAILED=1; }
ok()   { printf '[verify-vendor] OK: %s\n' "$*" >&2; }

FAILED=0

[ -d "$VENDOR_BIN" ] && [ -d "$VENDOR_LIB" ] || { echo "run scripts/vendor-codecs.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Copy vendor/ to an isolated temp dir
# ---------------------------------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squish-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp -R "$VENDOR_BIN" "$WORK/bin"
cp -R "$VENDOR_LIB" "$WORK/lib"
log "working copy: $WORK"

# A PATH with no Homebrew and no /usr/local — proves nothing on the system
# PATH is silently filling in a missing dependency (e.g. via dyld fallback
# search or a coincidentally-matching dylib version elsewhere).
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# 2. otool -L must show only /usr/lib, /System, and @executable_path
# ---------------------------------------------------------------------------

log "checking load commands on every vendored binary/dylib..."
for f in "$WORK"/bin/* "$WORK"/lib/*; do
    [ -f "$f" ] || continue
    bad="$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
        | grep -Ev '^(/usr/lib/|/System/|@executable_path/)' || true)"
    if [ -n "$bad" ]; then
        fail "$f references non-relocatable path(s): $(echo "$bad" | tr '\n' ' ')"
    fi
done
[ "$FAILED" = 0 ] && ok "all load commands are /usr/lib, /System, or @executable_path"

# ---------------------------------------------------------------------------
# 3. codesign must be valid (ad-hoc) on every file
# ---------------------------------------------------------------------------

log "checking ad-hoc code signatures..."
for f in "$WORK"/bin/* "$WORK"/lib/*; do
    [ -f "$f" ] || continue
    if ! codesign -v "$f" 2>/dev/null; then
        fail "$f has no valid signature"
    fi
done
[ "$FAILED" = 0 ] && ok "all binaries/dylibs carry a valid ad-hoc signature"

# ---------------------------------------------------------------------------
# 4. Build test images (magick preferred, sips/ImageIO fallback)
# ---------------------------------------------------------------------------

IMGDIR="$WORK/images"
mkdir -p "$IMGDIR"
SRC_PNG="$IMGDIR/source.png"

if command -v magick >/dev/null 2>&1; then
    # A photographic-ish gradient + noise pattern — big enough that lossy
    # encoders produce a materially smaller file, small enough to be fast.
    magick -size 640x480 plasma:fractal -blur 0x2 "$SRC_PNG"
elif command -v sips >/dev/null 2>&1; then
    # Fallback: sips can't synthesize an image from nothing, so make a
    # minimal raw canvas via Python/ImageIO... but sips needs a source
    # image. Use a 1x1 seed and resample as a last resort.
    python3 - "$SRC_PNG" <<'PY'
import sys, struct, zlib
w, h = 640, 480
def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
rows = bytearray()
for y in range(h):
    rows.append(0)
    for x in range(w):
        rows += bytes(((x*255//w), (y*255//h), ((x+y)*255//(w+h))))
raw = zlib.compress(bytes(rows), 9)
sig = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
with open(sys.argv[1], 'wb') as f:
    f.write(sig)
    f.write(chunk(b'IHDR', ihdr))
    f.write(chunk(b'IDAT', raw))
    f.write(chunk(b'IEND', b''))
PY
else
    echo "need either 'magick' or python3 to build a test image" >&2
    exit 1
fi

[ -s "$SRC_PNG" ] || fail "failed to create test PNG"
ok "test image: $SRC_PNG ($(stat -f%z "$SRC_PNG") bytes)"

# ---------------------------------------------------------------------------
# 5. Round-trip every tool, isolated from Homebrew (env -i, bare PATH)
# ---------------------------------------------------------------------------

run_isolated() {
    env -i PATH="$BARE_PATH" HOME="$WORK" "$@"
}

log "cjpeg: PNG -> JPEG (web-mode settings)..."
CJPEG_OUT="$IMGDIR/out.jpg"
if run_isolated "$WORK/bin/cjpeg" -quality 84 -sample 1x1 -progressive -outfile "$CJPEG_OUT" "$SRC_PNG"; then
    [ -s "$CJPEG_OUT" ] && ok "cjpeg produced $(stat -f%z "$CJPEG_OUT") bytes" || fail "cjpeg produced empty output"
else
    fail "cjpeg failed to run isolated from Homebrew"
fi

log "jpegtran: JPEG -> optimized JPEG..."
JPEGTRAN_OUT="$IMGDIR/out-opt.jpg"
if [ -s "$CJPEG_OUT" ] && run_isolated "$WORK/bin/jpegtran" -optimize -outfile "$JPEGTRAN_OUT" "$CJPEG_OUT"; then
    [ -s "$JPEGTRAN_OUT" ] && ok "jpegtran produced $(stat -f%z "$JPEGTRAN_OUT") bytes" || fail "jpegtran produced empty output"
else
    fail "jpegtran failed to run isolated from Homebrew"
fi

log "cwebp: PNG -> WebP..."
CWEBP_OUT="$IMGDIR/out.webp"
if run_isolated "$WORK/bin/cwebp" -quiet -q 82 "$SRC_PNG" -o "$CWEBP_OUT"; then
    [ -s "$CWEBP_OUT" ] && ok "cwebp produced $(stat -f%z "$CWEBP_OUT") bytes" || fail "cwebp produced empty output"
else
    fail "cwebp failed to run isolated from Homebrew"
fi

log "oxipng: PNG -> optimized PNG..."
OXIPNG_OUT="$IMGDIR/out-oxi.png"
cp "$SRC_PNG" "$OXIPNG_OUT"
if run_isolated "$WORK/bin/oxipng" -o 4 "$OXIPNG_OUT"; then
    [ -s "$OXIPNG_OUT" ] && ok "oxipng produced $(stat -f%z "$OXIPNG_OUT") bytes" || fail "oxipng produced empty output"
else
    fail "oxipng failed to run isolated from Homebrew"
fi

log "pngquant: PNG -> quantized PNG..."
PNGQUANT_OUT="$IMGDIR/out-quant.png"
if run_isolated "$WORK/bin/pngquant" --quality=65-90 --output "$PNGQUANT_OUT" "$SRC_PNG"; then
    [ -s "$PNGQUANT_OUT" ] && ok "pngquant produced $(stat -f%z "$PNGQUANT_OUT") bytes" || fail "pngquant produced empty output"
else
    fail "pngquant failed to run isolated from Homebrew"
fi

METRIC_BIN=""
for cand in ssimulacra2 dssim; do
    [ -x "$WORK/bin/$cand" ] && METRIC_BIN="$cand"
done
[ -n "$METRIC_BIN" ] || fail "no metric binary found in vendor/bin"

if [ "$METRIC_BIN" = ssimulacra2 ] && [ -s "$CJPEG_OUT" ]; then
    log "ssimulacra2: source.png vs out.jpg..."
    if SCORE="$(run_isolated "$WORK/bin/ssimulacra2" "$SRC_PNG" "$CJPEG_OUT")"; then
        ok "ssimulacra2 score: $SCORE"
    else
        fail "ssimulacra2 failed to run isolated from Homebrew"
    fi
elif [ "$METRIC_BIN" = dssim ] && [ -s "$CJPEG_OUT" ]; then
    log "dssim: source.png vs out.jpg..."
    if SCORE="$(run_isolated "$WORK/bin/dssim" "$SRC_PNG" "$CJPEG_OUT")"; then
        ok "dssim score: $SCORE"
    else
        fail "dssim failed to run isolated from Homebrew"
    fi
fi

# ---------------------------------------------------------------------------
# 6. mozjpeg-vs-jpeg-turbo sanity check (uses Homebrew's jpeg-turbo cjpeg
#    ONLY as the comparison baseline — the vendored binary itself was already
#    proven Homebrew-independent above)
# ---------------------------------------------------------------------------

if command -v brew >/dev/null 2>&1; then
    TURBO_CJPEG=""
    for candidate in /opt/homebrew/bin/cjpeg /usr/local/bin/cjpeg; do
        if [ -x "$candidate" ]; then
            if "$candidate" -version 2>&1 | grep -qi 'libjpeg-turbo'; then
                TURBO_CJPEG="$candidate"
                break
            fi
        fi
    done
    if [ -n "$TURBO_CJPEG" ] && [ -s "$SRC_PNG" ]; then
        TURBO_OUT="$IMGDIR/out-turbo.jpg"
        "$TURBO_CJPEG" -quality 84 -sample 1x1 -progressive -outfile "$TURBO_OUT" "$SRC_PNG" || true
        if [ -s "$TURBO_OUT" ] && [ -s "$CJPEG_OUT" ]; then
            MOZ_SIZE="$(stat -f%z "$CJPEG_OUT")"
            TURBO_SIZE="$(stat -f%z "$TURBO_OUT")"
            log "mozjpeg output: $MOZ_SIZE bytes, jpeg-turbo output: $TURBO_SIZE bytes (same settings)"
            if [ "$MOZ_SIZE" -lt "$TURBO_SIZE" ]; then
                ok "vendored cjpeg is meaningfully smaller than jpeg-turbo -> confirmed mozjpeg"
            else
                fail "vendored cjpeg is NOT smaller than jpeg-turbo at -quality 84 -sample 1x1 — may not be mozjpeg"
            fi
        else
            log "(skipping mozjpeg-vs-turbo size comparison: could not produce both outputs)"
        fi
    else
        log "(skipping mozjpeg-vs-turbo size comparison: no jpeg-turbo cjpeg found on this machine)"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Result
# ---------------------------------------------------------------------------

if [ "$FAILED" = 0 ]; then
    log "ALL CHECKS PASSED"
    exit 0
else
    log "ONE OR MORE CHECKS FAILED"
    exit 1
fi
