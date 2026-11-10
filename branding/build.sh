#!/usr/bin/env bash
# Regenerate every brand asset from the SVG sources in this directory.
#
#   branding/build.sh          writes branding/out/ (SVG + PNG)
#   branding/build.sh --sync   also copies the packaged subset into a faseela-repo
#                              checkout:  branding/build.sh --sync ../faseela-repo
#
# Needs: rsvg-convert (librsvg). The sources are the single source of truth;
# faseela-repo/recipes/extra/faseela-branding/assets holds a copy of the files
# that end up on the installed system.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
rm -rf "$out"
mkdir -p "$out/icons" "$out/mark"

command -v rsvg-convert >/dev/null || { echo "build.sh: rsvg-convert not found (librsvg)" >&2; exit 1; }

# colour variants of the bare mark
render_mark() { # name ink leaf gold
    sed -e "s/@INK@/$2/g" -e "s/@LEAF@/$3/g" -e "s/@GOLD@/$4/g" "$here/mark.tpl.svg" > "$out/mark/$1.svg"
}
render_mark mark-dark  '#0E1A2B' '#2F7D3E' '#D9A21B'   # for light backgrounds
render_mark mark-light '#EADFC8' '#5DBB63' '#E6B53A'   # for dark backgrounds
render_mark mark-mono  '#0E1A2B' '#0E1A2B' '#0E1A2B'   # one colour: stamps, favicons, print

# app icon: scalable + PNG sizes the freedesktop hicolor theme expects
cp "$here/icon.tpl.svg" "$out/icons/faseela.svg"
for s in 16 22 24 32 48 64 128 256 512; do
    rsvg-convert -w "$s" -h "$s" "$here/icon.tpl.svg" -o "$out/icons/faseela-$s.png"
done

# wallpaper
rsvg-convert -w 1920 -h 1080 "$here/wallpaper.svg" -o "$out/wallpaper-1920x1080.png"
rsvg-convert -w 2560 -h 1440 "$here/wallpaper.svg" -o "$out/wallpaper-2560x1440.png"

# GRUB theme: background, logo, highlight bar and theme.txt, ready to be copied to
# <boot>/grub/themes/faseela (the font comes from GRUB's own unicode.pf2)
mkdir -p "$out/grub"
rsvg-convert -w 1280 -h 720 "$here/grub-background.svg" -o "$out/grub/background.png"
rsvg-convert -w 128 -h 128 "$out/mark/mark-light.svg" -o "$out/grub/logo.png"
printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#1E3556"/></svg>' \
    | rsvg-convert -w 8 -h 8 -o "$out/grub/select_c.png"
cp "$here/grub/theme.txt" "$out/grub/theme.txt"

echo "wrote $out"

if [ "${1:-}" = "--sync" ]; then
    repo=${2:?usage: build.sh --sync PATH-TO-faseela-repo}
    dest="$repo/recipes/extra/faseela-branding/assets"
    rm -rf "$dest"
    mkdir -p "$dest/icons" "$dest/mark" "$dest/grub"
    cp "$out/icons/"* "$dest/icons/"
    cp "$out/mark/"* "$dest/mark/"
    cp "$out/grub/"* "$dest/grub/"
    cp "$out/wallpaper-1920x1080.png" "$out/wallpaper-2560x1440.png" "$dest/"
    echo "synced into $dest"
fi
