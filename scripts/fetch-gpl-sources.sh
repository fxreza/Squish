#!/bin/bash
# fetch-gpl-sources.sh — GPLv3 §6 "written offer" fulfillment.
#
# Squish bundles one GPL-3.0-or-later binary: pngquant (see ATTRIBUTION.md).
# GPLv3 §6 requires that anyone who receives that binary can obtain its exact
# corresponding source. This script downloads that exact upstream source
# package, verifies it against a pinned checksum, and drops it in
# gpl-sources/ — so "how do I get the source" has a one-command answer
# instead of only a promise in a text file.
#
# gpl-sources/ is gitignored (tarballs don't belong in git history); this
# script is what's committed and it is safe to re-run any time.
#
# Usage: scripts/fetch-gpl-sources.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/gpl-sources"

log() { printf '[fetch-gpl-sources] %s\n' "$*" >&2; }
die() { printf '[fetch-gpl-sources] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pin: the exact pngquant version currently vendored.
#
# Keep this in sync with whatever scripts/vendor-codecs.sh actually pulls in
# (check with `vendor/bin/pngquant --version` after a fresh vendoring run,
# and cross-reference `brew info pngquant`). As of this writing that's the
# version below, built by Homebrew's own `pngquant` formula straight from
# this crates.io source package — see
# https://github.com/Homebrew/homebrew-core/blob/master/Formula/p/pngquant.rb
# ---------------------------------------------------------------------------

PNGQUANT_VERSION="3.0.3"
PNGQUANT_URL="https://static.crates.io/crates/pngquant/pngquant-${PNGQUANT_VERSION}.crate"
PNGQUANT_SHA256="68a12bdd8825f9989f4ee9a6ab0b42727dae57728b939ef63453366697a07232"
PNGQUANT_OUT="$OUT_DIR/pngquant-${PNGQUANT_VERSION}.crate"

mkdir -p "$OUT_DIR"

sha256_of() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		die "neither shasum nor sha256sum is available to verify the download"
	fi
}

verify() {
	local file="$1" expected="$2" actual
	actual="$(sha256_of "$file")"
	[ "$actual" = "$expected" ]
}

if [ -f "$PNGQUANT_OUT" ] && verify "$PNGQUANT_OUT" "$PNGQUANT_SHA256"; then
	log "already have $PNGQUANT_OUT with a verified sha256 — skipping download."
else
	rm -f "$PNGQUANT_OUT"
	log "downloading pngquant $PNGQUANT_VERSION source from $PNGQUANT_URL"
	curl -fSL --retry 3 -o "$PNGQUANT_OUT.tmp" "$PNGQUANT_URL" || die "download failed"
	if ! verify "$PNGQUANT_OUT.tmp" "$PNGQUANT_SHA256"; then
		actual="$(sha256_of "$PNGQUANT_OUT.tmp")"
		rm -f "$PNGQUANT_OUT.tmp"
		die "sha256 mismatch for downloaded pngquant source: expected $PNGQUANT_SHA256, got $actual. Refusing to keep a tarball that doesn't match the pinned, vendored version — if pngquant was intentionally upgraded, update PNGQUANT_VERSION/PNGQUANT_SHA256 in this script (and vendor/bin/pngquant) together."
	fi
	mv "$PNGQUANT_OUT.tmp" "$PNGQUANT_OUT"
	log "verified sha256: $PNGQUANT_SHA256"
fi

cat <<EOF

pngquant $PNGQUANT_VERSION corresponding source: $PNGQUANT_OUT

This is the exact crates.io source package that Homebrew's "pngquant" formula
builds to produce the vendor/bin/pngquant binary Squish ships (confirmed
against the formula's own pinned url/sha256). It's a gzipped tar despite the
.crate extension — crates.io packages are plain tar.gz archives — and it
includes Cargo.lock, so it pins the exact version of libimagequant and every
other dependency that went into this build too.

Unpack with:
    tar xzf "$PNGQUANT_OUT" -C "$OUT_DIR"

See ATTRIBUTION.md for the full GPLv3 §6 written offer this script fulfills.
EOF
