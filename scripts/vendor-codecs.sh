#!/bin/bash
# vendor-codecs.sh — populate vendor/bin and vendor/lib with relocatable helper
# binaries for Squish. Installs missing Homebrew formulas, copies the binaries
# we need, then walks their full dylib dependency graph and rewrites every
# non-system load command to @executable_path/../lib/<name>, so the resulting
# vendor/ tree runs on a Mac with no Homebrew installed. Idempotent: safe to
# re-run any time (always re-copies fresh from Homebrew and re-relocates).
#
# Bash 3.2 compatible (that's what ships as /bin/bash on macOS) — no
# associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_BIN="$ROOT/vendor/bin"
VENDOR_LIB="$ROOT/vendor/lib"

log() { printf '[vendor-codecs] %s\n' "$*" >&2; }
die() { printf '[vendor-codecs] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$VENDOR_BIN" "$VENDOR_LIB"

# ---------------------------------------------------------------------------
# 1. Make sure Homebrew has what we need
# ---------------------------------------------------------------------------

command -v brew >/dev/null 2>&1 || die "Homebrew is required at build time (not found on PATH)"

require_brew_formula() {
    local formula="$1"
    if brew list --formula --versions "$formula" >/dev/null 2>&1; then
        log "$formula already installed ($(brew list --formula --versions "$formula"))"
    else
        log "installing $formula via Homebrew..."
        brew install "$formula"
    fi
}

require_brew_formula mozjpeg
require_brew_formula webp
require_brew_formula oxipng
require_brew_formula pngquant
require_brew_formula jpeg-xl   # ships a prebuilt ssimulacra2 tool — see metric selection below

MOZJPEG_PREFIX="$(brew --prefix mozjpeg)"
WEBP_PREFIX="$(brew --prefix webp)"
OXIPNG_PREFIX="$(brew --prefix oxipng)"
PNGQUANT_PREFIX="$(brew --prefix pngquant)"
JPEGXL_PREFIX="$(brew --prefix jpeg-xl)"

CJPEG_SRC="$MOZJPEG_PREFIX/bin/cjpeg"
JPEGTRAN_SRC="$MOZJPEG_PREFIX/bin/jpegtran"
CWEBP_SRC="$WEBP_PREFIX/bin/cwebp"
OXIPNG_SRC="$OXIPNG_PREFIX/bin/oxipng"
PNGQUANT_SRC="$PNGQUANT_PREFIX/bin/pngquant"

[ -x "$CJPEG_SRC" ]    || die "cjpeg not found at $CJPEG_SRC — is mozjpeg really installed (keg-only)?"
[ -x "$JPEGTRAN_SRC" ] || die "jpegtran not found at $JPEGTRAN_SRC"
[ -x "$CWEBP_SRC" ]    || die "cwebp not found at $CWEBP_SRC"
[ -x "$OXIPNG_SRC" ]   || die "oxipng not found at $OXIPNG_SRC"
[ -x "$PNGQUANT_SRC" ] || die "pngquant not found at $PNGQUANT_SRC"

# Sanity: make sure we really grabbed mozjpeg's cjpeg, not jpeg-turbo's (they
# have the same binary name and jpeg-turbo's may also be on PATH via
# /opt/homebrew/bin/cjpeg). mozjpeg's -version banner says "mozjpeg version";
# jpeg-turbo's says "libjpeg-turbo version". The real proof (quality/size at
# fixed settings) happens in verify-vendor.sh, but fail fast here too.
CJPEG_BANNER="$("$CJPEG_SRC" -version 2>&1 || true)"
case "$CJPEG_BANNER" in
    *mozjpeg*) log "confirmed mozjpeg build: $CJPEG_BANNER" ;;
    *) die "vendored cjpeg at $CJPEG_SRC does not identify as mozjpeg: $CJPEG_BANNER" ;;
esac

# ---------------------------------------------------------------------------
# 2. Perceptual metric binary selection (investigate in spec order, stop at
#    the first that works)
# ---------------------------------------------------------------------------

METRIC_NAME=""
METRIC_SRC=""

# (a) does the jpeg-xl keg ship an ssimulacra2 tool?
if [ -x "$JPEGXL_PREFIX/bin/ssimulacra2" ]; then
    METRIC_NAME="ssimulacra2"
    METRIC_SRC="$JPEGXL_PREFIX/bin/ssimulacra2"
    log "metric: using ssimulacra2 shipped by the jpeg-xl keg ($METRIC_SRC)"
fi

# (b) cargo install ssimulacra2_bin
if [ -z "$METRIC_SRC" ]; then
    if ! command -v cargo >/dev/null 2>&1; then
        log "cargo not found; installing rust via Homebrew for ssimulacra2_bin fallback"
        brew install rust || true
    fi
    if command -v cargo >/dev/null 2>&1; then
        log "attempting: cargo install ssimulacra2_bin"
        if cargo install ssimulacra2_bin 2>&1 | tee /tmp/ssimulacra2_bin_install.log; then
            CARGO_BIN="$(dirname "$(command -v cargo)")"
            for candidate in "$HOME/.cargo/bin/ssimulacra2" "$CARGO_BIN/ssimulacra2"; do
                if [ -x "$candidate" ]; then
                    METRIC_NAME="ssimulacra2"
                    METRIC_SRC="$candidate"
                    log "metric: using cargo-built ssimulacra2_bin ($METRIC_SRC)"
                    break
                fi
            done
        fi
    fi
fi

# (c) build from the libjxl source tree — last-resort, skipped here since (a)
#     already succeeded in practice on this machine; left as documented dead
#     code path for future maintainers if (a) and (b) both fail upstream.
if [ -z "$METRIC_SRC" ]; then
    log "ssimulacra2 unavailable via (a) keg tool or (b) cargo; a from-source libjxl build" \
        "would be step (c) but is not automated here — falling back to dssim."
fi

# (d) last resort: dssim
if [ -z "$METRIC_SRC" ]; then
    require_brew_formula dssim
    DSSIM_PREFIX="$(brew --prefix dssim)"
    if [ -x "$DSSIM_PREFIX/bin/dssim" ]; then
        METRIC_NAME="dssim"
        METRIC_SRC="$DSSIM_PREFIX/bin/dssim"
        log "metric: falling back to dssim ($METRIC_SRC)"
    fi
fi

[ -n "$METRIC_SRC" ] || die "no perceptual metric binary could be obtained (tried ssimulacra2 keg tool, cargo ssimulacra2_bin, dssim)"

# ---------------------------------------------------------------------------
# 3. Dependency graph discovery (operates on the ORIGINAL Homebrew files,
#    fully resolvable in place — @rpath/@loader_path/@executable_path all
#    expand correctly there). Builds two parallel lists:
#      ROOT_ORIG[]/ROOT_NAME[]   -> binaries that land in vendor/bin
#      DISC_ORIG[]/DISC_NAME[]   -> transitive dylibs that land in vendor/lib
# ---------------------------------------------------------------------------

ROOT_ORIG=()
ROOT_NAME=()
DISC_ORIG=()
DISC_NAME=()

add_root() {
    local orig name
    orig="$(realpath "$1")"
    name="$2"
    ROOT_ORIG+=("$orig")
    ROOT_NAME+=("$name")
}

is_discovered() {
    local target="$1" p
    for p in "${DISC_ORIG[@]:-}"; do
        [ "$p" = "$target" ] && return 0
    done
    return 1
}

# Print each LC_RPATH entry of a Mach-O file, one per line.
get_rpaths() {
    otool -l "$1" 2>/dev/null | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}'
}

# Resolve a dependency token (as printed by `otool -L`) to an absolute real
# path, given the file that referenced it. Prints "SYSTEM" for anything under
# /usr/lib or /System (present on every Mac, left unmodified). Dies if an
# @rpath/@loader_path/@executable_path reference cannot be resolved.
resolve_dep() {
    local token="$1" referrer="$2" referrer_dir rest rp expanded candidate
    case "$token" in
        /usr/lib/*|/System/*)
            echo "SYSTEM"; return 0 ;;
        @rpath/*)
            rest="${token#@rpath/}"
            referrer_dir="$(dirname "$referrer")"
            while IFS= read -r rp; do
                [ -z "$rp" ] && continue
                case "$rp" in
                    @loader_path/*|@executable_path/*)
                        expanded="$referrer_dir/${rp#@*_path/}" ;;
                    *)
                        expanded="$rp" ;;
                esac
                candidate="$expanded/$rest"
                if [ -f "$candidate" ]; then
                    realpath "$candidate"
                    return 0
                fi
            done <<< "$(get_rpaths "$referrer")"
            die "could not resolve $token referenced from $referrer (checked rpaths: $(get_rpaths "$referrer" | tr '\n' ' '))"
            ;;
        @loader_path/*|@executable_path/*)
            rest="${token#@*_path/}"
            referrer_dir="$(dirname "$referrer")"
            realpath "$referrer_dir/$rest"
            ;;
        /*)
            realpath "$token"
            ;;
        *)
            die "unexpected dependency token '$token' in $referrer"
            ;;
    esac
}

# List the non-self dependency tokens of a Mach-O file as printed by otool -L
# (skips the header line; for a dylib also skips its own LC_ID_DYLIB line).
list_dep_tokens() {
    local file="$1" self_id
    self_id="$(otool -D "$file" 2>/dev/null | tail -n +2 | head -n1 || true)"
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while IFS= read -r tok; do
        [ -n "$self_id" ] && [ "$tok" = "$self_id" ] && continue
        echo "$tok"
    done
}

discover() {
    local orig="$1" name="$2" tok resolved
    is_discovered "$orig" && return 0
    DISC_ORIG+=("$orig")
    DISC_NAME+=("$name")
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        resolved="$(resolve_dep "$tok" "$orig")"
        [ "$resolved" = "SYSTEM" ] && continue
        discover "$resolved" "$(basename "$resolved")"
    done <<< "$(list_dep_tokens "$orig")"
}

scan_root_deps() {
    local orig="$1" tok resolved
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        resolved="$(resolve_dep "$tok" "$orig")"
        [ "$resolved" = "SYSTEM" ] && continue
        discover "$resolved" "$(basename "$resolved")"
    done <<< "$(list_dep_tokens "$orig")"
}

add_root "$CJPEG_SRC" cjpeg
add_root "$JPEGTRAN_SRC" jpegtran
add_root "$CWEBP_SRC" cwebp
add_root "$OXIPNG_SRC" oxipng
add_root "$PNGQUANT_SRC" pngquant
add_root "$METRIC_SRC" "$METRIC_NAME"

for orig in "${ROOT_ORIG[@]}"; do
    scan_root_deps "$orig"
done

log "discovered ${#DISC_ORIG[@]} transitive dylib(s) for ${#ROOT_ORIG[@]} root binaries"

# ---------------------------------------------------------------------------
# 4. Copy phase
# ---------------------------------------------------------------------------

rm -rf "$VENDOR_BIN" "$VENDOR_LIB"
mkdir -p "$VENDOR_BIN" "$VENDOR_LIB"

for i in "${!ROOT_ORIG[@]}"; do
    cp "${ROOT_ORIG[$i]}" "$VENDOR_BIN/${ROOT_NAME[$i]}"
    chmod u+w,+x "$VENDOR_BIN/${ROOT_NAME[$i]}"
done

for i in "${!DISC_ORIG[@]}"; do
    cp "${DISC_ORIG[$i]}" "$VENDOR_LIB/${DISC_NAME[$i]}"
    chmod u+w "$VENDOR_LIB/${DISC_NAME[$i]}"
done

# ---------------------------------------------------------------------------
# 5. Rewrite phase — repoint every non-system load command at
#    @executable_path/../lib/<name>, and set each vendored dylib's own ID
#    the same way, so it's consistent whether it's loaded by a vendor/bin
#    binary or by another vendor/lib dylib (both live under the app's
#    Resources/{bin,lib}, i.e. @executable_path always means Resources/bin).
# ---------------------------------------------------------------------------

relocate_file() {
    local orig="$1" vendor_path="$2" tok resolved name
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        resolved="$(resolve_dep "$tok" "$orig")"
        [ "$resolved" = "SYSTEM" ] && continue
        name="$(basename "$resolved")"
        install_name_tool -change "$tok" "@executable_path/../lib/$name" "$vendor_path"
    done <<< "$(list_dep_tokens "$orig")"
}

for i in "${!ROOT_ORIG[@]}"; do
    relocate_file "${ROOT_ORIG[$i]}" "$VENDOR_BIN/${ROOT_NAME[$i]}"
done

for i in "${!DISC_ORIG[@]}"; do
    dylib="$VENDOR_LIB/${DISC_NAME[$i]}"
    install_name_tool -id "@executable_path/../lib/${DISC_NAME[$i]}" "$dylib"
    relocate_file "${DISC_ORIG[$i]}" "$dylib"
done

# ---------------------------------------------------------------------------
# 6. Re-sign everything ad-hoc (install_name_tool invalidates signatures;
#    macOS refuses to run unsigned-after-modification arm64 binaries)
# ---------------------------------------------------------------------------

for f in "$VENDOR_BIN"/* "$VENDOR_LIB"/*; do
    [ -f "$f" ] || continue
    codesign --force --sign - "$f"
done

log "done. vendor/bin: $(ls "$VENDOR_BIN" | tr '\n' ' ')"
log "vendor/lib: $(ls "$VENDOR_LIB" | wc -l | tr -d ' ') dylib(s)"
log "shipped metric binary: $METRIC_NAME"
du -sh "$ROOT/vendor" >&2
