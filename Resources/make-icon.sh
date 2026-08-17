#!/bin/bash
set -euo pipefail

# Regenerates MicPin.icns from icon.svg.
#
# The .icns is committed so a normal build needs no extra tooling; only run
# this after editing icon.svg. Needs librsvg (brew install librsvg).

cd "$(dirname "$0")"

if ! command -v rsvg-convert >/dev/null; then
    echo "rsvg-convert not found — brew install librsvg" >&2
    exit 1
fi

SET=MicPin.iconset
rm -rf "$SET"
mkdir "$SET"

render() {
    rsvg-convert -w "$1" -h "$1" icon.svg -o "$SET/$2.png"
}

render 16   icon_16x16
render 32   icon_16x16@2x
render 32   icon_32x32
render 64   icon_32x32@2x
render 128  icon_128x128
render 256  icon_128x128@2x
render 256  icon_256x256
render 512  icon_256x256@2x
render 512  icon_512x512
render 1024 icon_512x512@2x

iconutil -c icns "$SET" -o MicPin.icns
rm -rf "$SET"

echo "wrote MicPin.icns ($(stat -f%z MicPin.icns) bytes)"
