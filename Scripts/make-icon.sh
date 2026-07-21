#!/bin/bash
#
# make-icon.sh — render every icon Vestige needs from Resources/icon.png.
#
# Produces:
#   Resources/AppIcon.icns        the app icon, on a macOS-style rounded plate
#   Resources/MenuBarIcon.png     menu bar glyph, 18pt template
#   Resources/MenuBarIcon@2x.png
#
# The master is the PNG rather than icon.svg. The source SVG places the
# clapperboard's separator strips with a rotate() transform, and ImageMagick's
# built-in SVG renderer misplaces them; the PNG is a correct export from the
# original artwork. icon.svg is kept as the editable original.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT/Resources/icon.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$MASTER" ]; then
    echo "Missing $MASTER" >&2
    exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick is required: brew install imagemagick" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# App icon
# ---------------------------------------------------------------------------
#
# Apple's icon grid leaves a margin around the plate so icons of different
# shapes look optically equal in the Dock. 824/1024 with a 185pt corner radius
# matches the proportions macOS uses for its own app icons. The artwork is
# already full-bleed on its own background, so it becomes the plate directly.

echo "==> Building app icon plate"
PLATE=824
RADIUS=185

magick -size "${PLATE}x${PLATE}" xc:black -fill white \
    -draw "roundrectangle 0,0,$((PLATE - 1)),$((PLATE - 1)),$RADIUS,$RADIUS" \
    "$WORK/mask.png"

magick "$MASTER" -resize "${PLATE}x${PLATE}!" \
    "$WORK/mask.png" -alpha off -compose CopyOpacity -composite \
    "$WORK/rounded.png"

magick "$WORK/rounded.png" -background none -gravity center \
    -extent 1024x1024 "$WORK/appicon.png"

echo "==> Packing .icns"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    px="${spec%%:*}"
    name="${spec##*:}"
    magick "$WORK/appicon.png" -resize "${px}x${px}" "$ICONSET/$name.png"
done
iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# Menu bar template
# ---------------------------------------------------------------------------
#
# A template image is pure black plus an alpha channel; macOS recolours it for
# light, dark, and highlighted states, so any colour in it would be discarded.
#
# The alpha is taken from the artwork's own luminance. That is not a shortcut —
# it is what produces correct holes. The D-pad and the four buttons are drawn in
# the dark background colour on top of the light bubble, so mapping "light" to
# opaque and "dark" to transparent knocks them out exactly, with antialiased
# edges surviving as partial alpha instead of the halo that colour-keying leaves.

echo "==> Building menu bar template"

magick "$MASTER" -colorspace gray -auto-level "$WORK/luma.png"

magick -size 1000x1000 xc:black "$WORK/luma.png" \
    -alpha off -compose CopyOpacity -composite \
    "$WORK/template.png"

# Trim to the artwork's own bounds so the glyph fills the menu bar slot rather
# than floating inside the square canvas's empty margins.
magick "$WORK/template.png" -trim +repage "$WORK/template-trimmed.png"

# Menu bar items get roughly 18pt of height. Fitting the glyph inside 16pt
# leaves the breathing room SF Symbols have there.
magick "$WORK/template-trimmed.png" -resize 32x32 -background none -gravity center \
    -extent 36x36 "$ROOT/Resources/MenuBarIcon@2x.png"
magick "$WORK/template-trimmed.png" -resize 16x16 -background none -gravity center \
    -extent 18x18 "$ROOT/Resources/MenuBarIcon.png"

echo "==> Wrote:"
echo "    Resources/AppIcon.icns"
echo "    Resources/MenuBarIcon.png"
echo "    Resources/MenuBarIcon@2x.png"
