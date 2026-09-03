# Attribution

Squish's own source (`Sources/`, `scripts/`, `raycast/`, `quickactions/`, `tests/`) is licensed
under the MIT License - see `LICENSE`.

**That MIT license does not extend to `vendor/bin` and `vendor/lib`.** Those directories are
populated at build time by `scripts/vendor-codecs.sh`, which installs a handful of Homebrew
formulas and copies their compiled binaries and dylibs straight into the app bundle
(`Squish.app/Contents/Resources/{bin,lib}`). Every file there keeps its own upstream license,
and one of them is copyleft. Read the "pngquant" section below before you ship a build.

This file exists to satisfy the attribution/notice terms of those upstream projects, and to make
the licensing situation legible to anyone deciding whether/how to distribute `Squish.app`. It is
not legal advice; if you plan to distribute Squish beyond personal use, have a lawyer confirm the
conclusions below, especially the pngquant one.

---

## Summary table

| Binary / dylib | Project | License | Redistribution |
|---|---|---|---|
| `cjpeg`, `jpegtran` | [mozjpeg](https://github.com/mozilla/mozjpeg) | IJG AND Zlib AND BSD-3-Clause | OK |
| `cwebp`, `libwebp*.dylib`, `libsharpyuv*.dylib` | [libwebp](https://chromium.googlesource.com/webm/libwebp) (Google, "WebP Project") | BSD-3-Clause | OK |
| `oxipng` | [oxipng](https://github.com/oxipng/oxipng) | MIT | OK |
| `pngquant` | [pngquant](https://pngquant.org/) / libimagequant | **GPL-3.0-or-later** (+ HPND, BSD-2-Clause) | **See below - not a plain OK** |
| `ssimulacra2` | [libjxl](https://github.com/libjxl/libjxl) (JPEG XL reference implementation) | BSD-3-Clause | OK |
| `dssim` (fallback metric, **not currently vendored**) | [dssim](https://github.com/kornelski/dssim) | **AGPL-3.0-or-later** | **Would not be OK - see below** |
| 26 transitive `vendor/lib/*.dylib` | see [Transitive dylibs](#transitive-dylibs-vendorlib) | all permissive | OK |

"OK" means: permissive license, redistribution of the compiled binary inside a closed- or
open-source app is unproblematic beyond carrying the copyright notice and license text forward
(which this file, plus the license texts, does).

---

## The codecs Squish ships

### mozjpeg (`cjpeg`, `jpegtran`)

- Project: [mozilla/mozjpeg](https://github.com/mozilla/mozjpeg), a fork of libjpeg-turbo
- Copyright: Mozilla and the mozjpeg/libjpeg-turbo contributors; original code (c) the
  Independent JPEG Group
- License: **IJG AND Zlib AND BSD-3-Clause** (three licenses covering different parts of the
  codebase - the IJG license on the libjpeg-derived core, zlib license on some Huffman/arithmetic
  coding files, modified BSD on mozjpeg's own additions)
- Vendored via Homebrew formula `mozjpeg`
- All three components are permissive. The IJG license specifically asks that products derived
  from this software carry an acknowledgment: *"this software is based in part on the work of
  the Independent JPEG Group"* - include that line in Squish's own about box / credits screen,
  not just in this file.

### libwebp (`cwebp`)

- Project: Google's [WebP Project](https://developers.google.com/speed/webp)
- Copyright: Google Inc.
- License: **BSD-3-Clause**
- Vendored via Homebrew formula `webp`
- Permissive. `libsharpyuv` (a `vendor/lib` dylib) ships from the same project/formula under the
  same license.

### oxipng

- Project: [oxipng/oxipng](https://github.com/oxipng/oxipng)
- Copyright: Joshua Holmer and contributors
- License: **MIT**
- Vendored via Homebrew formula `oxipng`
- Permissive.

### pngquant - **copyleft, read this**

- Project: [pngquant](https://pngquant.org/) (Kornel Lesiński), built on libimagequant
- Copyright: Kornel Lesiński (2009-present); original quantization code by Jef Poskanzer (1989,
  1991); PNG I/O code by Greg Roelofs (1997-2014, relicensed to 2-clause BSD in 2014)
- License, as reported by Homebrew's own formula metadata (`brew info --json pngquant`):
  **`GPL-3.0-or-later AND HPND AND BSD-2-Clause`**. libimagequant alone is tagged
  `GPL-3.0-or-later AND HPND`. pngquant.org states plainly: *"pngquant and libimagequant... are
  available under the GPL or a commercial license."*
- HPND (Historical Permission Notice and Disclaimer, covering Poskanzer's original code) and
  BSD-2-Clause (Roelofs' PNG I/O code) are permissive on their own. But the compiled `pngquant`
  binary is a single linked combination of all of that code plus Lesiński's GPLv3-licensed
  additions, and the strongest license in a combined work governs the whole binary. **The
  `pngquant` executable Squish vendors is effectively GPL-3.0-or-later.**

**Why this matters for Squish**: `vlossless` mode on PNG input calls `pngquant` (see
`docs/SPEC.md`) - it is not optional, load-bearing functionality, not an extra. Distributing
`Squish.app` therefore means distributing a GPLv3 binary as part of the app bundle. Under GPLv3
that carries real obligations for that binary specifically:

1. **Include a full copy of the GPLv3 license text** alongside the binary (not just linked to
   from this file). `Squish.app/Contents/Resources` should ship one, and it isn't there yet as of
   this writing - `scripts/build-app.sh` doesn't copy any license text into the bundle. That's a
   gap someone with write access to `scripts/` should close.
2. **Make the corresponding source available** for the *exact* pngquant version vendored (a
   written offer, or a link to the tagged release/commit on GitHub, is enough - you don't have to
   bundle the source itself). Pin the vendored version (`vendor-codecs.sh` currently just grabs
   whatever Homebrew's `pngquant` formula resolves to "latest" - recording the resolved version
   string in the build log or a `VENDOR-VERSIONS.txt` would make "corresponding source" concrete
   instead of a moving target).
3. **Preserve copyright/license notices** - covered by this file plus (1).

There's a genuinely gray area beyond the three items above: GPLv3's copyleft only reaches
programs that are *combined* with the GPL'd code, not programs that merely sit next to it and
communicate at arm's length (the FSF calls the latter "mere aggregation," and it does not extend
GPL obligations to the other programs). Squish's Swift code never links against pngquant - it
shells out to the binary as a subprocess (`Process`/`NSTask`), the same pattern many
non-GPL apps use to call GPL CLI tools like `ffmpeg`. That's a reasonable basis for treating
Swift's own code as *not* becoming GPL. But bundling that GPL binary inside a single `.app` you
build, sign, and distribute as one artifact is a less clean case than, say, telling users to
install `pngquant` themselves via Homebrew - some read "single distributed artifact" as edging
toward a "combined work," and the FSF's own FAQ on this point is not a bright line. This
repository being open source under MIT (rather than a closed-source product) meaningfully reduces
the practical risk - the spirit of GPL's source-availability requirement is already satisfied for
everything *except* pngquant's own corresponding source, per item 2 above - but it does not make
the three formal obligations above optional.

**If you want zero ambiguity**: either (a) purchase a commercial libimagequant/pngquant license
from Kornel Lesiński before distributing Squish outside personal use, or (b) drop pngquant from
`vlossless`'s PNG path and accept a worse palette-quantization result (oxipng alone doesn't do
palette quantization - it losslessly re-compresses whatever palette/depth the PNG already has).
Neither of those is this document's call to make; it's the user's.

### ssimulacra2 (perceptual metric)

- Project: [libjxl/libjxl](https://github.com/libjxl/libjxl) (the JPEG XL reference
  implementation ships an `ssimulacra2` CLI tool)
- Copyright: the JPEG XL Project Authors
- License: **BSD-3-Clause**
- Vendored via Homebrew formula `jpeg-xl` (this is the binary actually shipped in `vendor/bin` as
  of this writing - confirmed by `vendor-codecs.sh`'s own version-banner check)
- Permissive.

### dssim (fallback metric - **not currently vendored, but watch for it**)

`docs/SPEC.md` specifies dssim as the fallback perceptual metric if ssimulacra2 can't be
obtained, and `scripts/vendor-codecs.sh` implements that fallback (Homebrew formula `dssim`, used
only if the `jpeg-xl` keg's `ssimulacra2` tool and a `cargo install ssimulacra2_bin` both fail).
Homebrew reports dssim's license as **AGPL-3.0-or-later** - a stronger copyleft than pngquant's
plain GPLv3 (AGPL additionally reaches network use, though that clause is irrelevant to a local
CLI tool; the core source-availability and license-text obligations are the same flavor as
pngquant's, described above, and would attach to whichever machine's vendoring run happens to
fall back to it).

**As of this writing dssim is not what's vendored** (`vendor/bin/ssimulacra2` exists,
`vendor/bin/dssim` does not) - so this is a latent risk, not a current one. But because the
fallback is silent (a log line, not a build failure), a future `vendor-codecs.sh` run on a
machine where the `jpeg-xl` keg tool and cargo both fail would ship an AGPL binary without any
code change and without anyone necessarily noticing. `.github/workflows/ci.yml` adds a warning
annotation if this happens on a CI run precisely because of this risk - but that only covers CI,
not someone's laptop. If dssim ever does ship, it needs the same three-item treatment as pngquant
above (own copy of AGPLv3 text, corresponding source for the exact version, notices preserved),
and is a second, independent reason to look hard at whether the app bundle needs to start
carrying license texts.

---

## Transitive dylibs (`vendor/lib`)

`vendor-codecs.sh` walks the full dependency graph of the binaries above and copies every
non-system dylib they load into `vendor/lib`, relocating each one's load paths to
`@executable_path/../lib`. As of this writing that's 26 files. All of them are permissively
licensed - no other copyleft surprises here:

| dylib(s) | Project | License |
|---|---|---|
| `libIex*`, `libIlmThread*`, `libImath*`, `libOpenEXR*`, `libOpenEXRCore*`, `libOpenEXRUtil*` | OpenEXR / Imath (Academy Software Foundation) | BSD-3-Clause |
| `libbrotlicommon*`, `libbrotlidec*`, `libbrotlienc*` | Brotli (Google) | MIT |
| `libdeflate*` | libdeflate (Eric Biggers) | MIT |
| `libgif*` | giflib | MIT |
| `libhwy*` | Highway (Google) - SIMD library used by libjxl | Apache-2.0 OR BSD-3-Clause |
| `libjpeg.62.*` | mozjpeg's own libjpeg replacement | IJG AND Zlib AND BSD-3-Clause (same as mozjpeg above) |
| `libjpeg.8.*` | plain IJG libjpeg (Homebrew formula `jpeg`), pulled in as a transitive dependency of another vendored library | IJG |
| `libjxl*`, `libjxl_cms*`, `libjxl_threads*` | libjxl | BSD-3-Clause |
| `liblcms2*` | Little CMS (Marti Maria Saguer) | MIT |
| `liblzma*` | xz-utils | **Public domain** for the `liblzma` runtime library itself (Homebrew tags the whole `xz` package `0BSD AND GPL-2.0-or-later`, but the GPL portion covers the package's helper shell scripts/build files, which are not vendored - only `liblzma.dylib` is) |
| `libopenjph*` | OpenJPH (HTJ2K, used by libjxl) | BSD-2-Clause |
| `libpng16*` | libpng | libpng License (permissive, attribution-only) |
| `libtiff*` | libtiff | libtiff License (permissive, attribution-only) |
| `libwebp*`, `libwebpdemux*`, `libsharpyuv*` | libwebp (Google) | BSD-3-Clause |
| `libzstd*` | Zstandard (Meta Platforms) | BSD-3-Clause OR GPL-2.0-only (dual-licensed; Squish relies on the BSD option) AND BSD-2-Clause AND MIT for smaller embedded components |

Every license in this table is permissive: attribution is required (this file, plus each
project's own copyright headers baked into the compiled binaries), but none of them impose
copyleft or restrict redistribution inside a closed- or open-source app.

---

## Outstanding action item for whoever owns `scripts/build-app.sh`

None of the license texts referenced above (GPLv3 for pngquant, BSD-3-Clause, MIT, IJG, Apache-2.0,
libpng/libtiff licenses) are currently copied into `Squish.app/Contents/Resources` at build time.
For a binary distributed beyond your own machine, that's the gap to close - most apps that bundle
third-party binaries ship a `Resources/LICENSES/` or an in-app "Acknowledgements" panel built
from a manifest like this file. This document is the source of truth for what needs to go in
there; wiring it into the actual bundle is a `scripts/build-app.sh` change, outside what this file
can do on its own.
