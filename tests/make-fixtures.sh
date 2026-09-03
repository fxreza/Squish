#!/bin/bash
# Regenerates tests/fixtures. Requires ImageMagick (`brew install imagemagick`).
# Fixtures are deliberately synthetic so they are reproducible on any machine.
set -euo pipefail
cd "$(dirname "$0")/fixtures"

FONT="/System/Library/Fonts/Supplemental/Arial.ttf"
FONT_BOLD="/System/Library/Fonts/Supplemental/Arial Bold.ttf"

rm -f photo.jpg landscape.tif screenshot.png alpha.png oriented.jpg \
      real-photo.jpg real-photo-crop.png mix-ui-photo.png

# --- photographic: fractal plasma smoothed into gradients, then sensor-like noise -----------
magick -size 1600x1200 plasma:fractal -blur 0x3 -attenuate 0.35 +noise Gaussian \
  -modulate 100,135,100 -depth 8 photo-src.png
magick photo-src.png -quality 95 -sampling-factor 4:2:0 photo.jpg
# distinct stem on purpose: photo.tif would collide with photo.jpg's output name
magick photo-src.png -compress none landscape.tif

# --- screenshot-like: flat fills, hard edges, rendered text ---------------------------------
magick -size 1440x900 xc:'#f2f2f7' \
  -fill '#ffffff' -draw 'roundrectangle 60,60 1380,220 12,12' \
  -font "$FONT_BOLD" -fill '#1d1d1f' -pointsize 54 -annotate +110+150 'Squish' \
  -font "$FONT" -fill '#6e6e73' -pointsize 28 -annotate +110+195 'Compress images without thinking about it' \
  -fill '#ffffff' -draw 'roundrectangle 60,260 700,840 12,12' \
  -fill '#ffffff' -draw 'roundrectangle 740,260 1380,840 12,12' \
  -fill '#007aff' -draw 'roundrectangle 110,320 400,380 8,8' \
  -fill '#ffffff' -pointsize 30 -annotate +150+362 'Compress' \
  -fill '#34c759' -draw 'roundrectangle 790,320 1080,380 8,8' \
  -fill '#ffffff' -pointsize 30 -annotate +830+362 'Visually lossless' \
  -fill '#3a3a3c' -pointsize 24 \
  -annotate +110+450 'jpeg   mozjpeg, fixed quality 84, progressive' \
  -annotate +110+500 'webp   cwebp, fixed quality 82' \
  -annotate +110+550 'vloss  binary search to a metric target' \
  -fill '#d1d1d6' -draw 'rectangle 110,600 660,602' \
  -fill '#ff3b30' -draw 'roundrectangle 790,450 900,510 6,6' \
  -fill '#ff9500' -draw 'roundrectangle 920,450 1030,510 6,6' \
  screenshot.png

# --- PNG with a real alpha channel ----------------------------------------------------------
magick -size 800x600 xc:none \
  -fill '#ff5722' -draw 'circle 280,300 280,110' \
  -fill 'rgba(33,150,243,0.65)' -draw 'roundrectangle 360,180 740,470 36,36' \
  -font "$FONT_BOLD" -fill '#ffffff' -pointsize 64 -annotate +430+340 'alpha' \
  alpha.png

# --- JPEG carrying EXIF orientation 6 (display = rotate 90 CW) ------------------------------
# ImageMagick will not write a fresh EXIF block onto a JPEG that had none, so the APP1 segment
# is assembled by hand: "Exif\0\0", a big-endian TIFF header, and a single Orientation entry.
magick photo-src.png -resize 1200x900! -quality 92 oriented-base.jpg
python3 - <<'PY'
import struct
src = open('oriented-base.jpg','rb').read()
payload = b'Exif\x00\x00' + b'MM' + struct.pack('>H', 42) + struct.pack('>I', 8) \
    + struct.pack('>H', 1) \
    + struct.pack('>HHI', 0x0112, 3, 1) + struct.pack('>HH', 6, 0) \
    + struct.pack('>I', 0)
segment = b'\xff\xe1' + struct.pack('>H', len(payload) + 2) + payload
i = 2
if src[2:4] == b'\xff\xe0':
    i = 4 + struct.unpack('>H', src[4:6])[0]
open('oriented.jpg','wb').write(src[:i] + segment + src[i:])
PY
rm -f oriented-base.jpg photo-src.png

# --- real photographic material -------------------------------------------------------------
# The chroma heuristic cannot be calibrated on synthetic images: plasma+noise is far noisier
# than any camera output, which is exactly how an earlier version came to classify every real
# photograph as graphics. These come from a genuine photograph shipped with macOS.
AERIAL="/System/Library/Wallpapers/.default/DefaultAerial.heic"
if [ -f "$AERIAL" ]; then
    magick "$AERIAL" -resize 1920x -quality 92 real-photo.jpg
    magick "$AERIAL" -crop 900x700+2200+1300 +repage real-photo-crop.png
    # a UI screenshot with a photograph pasted into it: text that must not be smeared, on top of
    # photographic content that on its own would read as 4:2:0
    magick screenshot.png \
      \( real-photo.jpg -resize 620x570^ -gravity center -crop 620x570+0+0 +repage \) \
      -geometry +70+265 -composite mix-ui-photo.png
else
    echo "warning: $AERIAL not found; the real-photograph fixtures were not generated" >&2
fi

ls -la
