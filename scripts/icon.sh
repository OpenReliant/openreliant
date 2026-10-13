#!/usr/bin/env bash
# usage: icon.sh
#
# Makes OpenReliant's icon from its SVG, assets/icon/openreliant.svg: the PNGs beside it, the
# Windows .ico the executables carry, and the macOS .icns. The files are committed, so a build needs
# none of the tools this script uses: rsvg-convert (librsvg), icotool (icoutils) and macOS's
# iconutil.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/assets/icon"
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT

# Draws the SVG as a square PNG: draw <size> <file>.
draw() {
    rsvg-convert --width "$1" --height "$1" openreliant.svg --output "$2"
}

# The PNGs, from the smallest size an icon is shown at to the largest.
for size in 16 32 48 64 128 256 512 1024; do
    draw "$size" "openreliant-$size.png"
done

# The .ico, at the sizes Windows shows an executable's icon at, for displays scaled from 100% to
# 250%, and in its largest view. The largest is kept as a PNG, as Windows reads it since Vista, and
# the others as bitmaps.
sizes=()
for size in 16 20 24 32 40 48 64; do
    draw "$size" "$work/$size.png"
    sizes+=("$work/$size.png")
done
icotool --create --output openreliant.ico "${sizes[@]}" --raw openreliant-256.png

# The .icns, with each of macOS's sizes at 1x and at 2x.
iconset="$work/openreliant.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    cp "openreliant-$size.png" "$iconset/icon_${size}x${size}.png"
    cp "openreliant-$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil --convert icns --output openreliant.icns "$iconset"
