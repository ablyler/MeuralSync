#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SVG="$ROOT_DIR/Assets/AppIcon.svg"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

ICONSET="$(mktemp -d /tmp/AppIcon.XXXXXX).iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$ICONSET"' EXIT

render() {
    local size="$1"
    local name="$2"
    rsvg-convert -w "$size" -h "$size" -o "$ICONSET/$name" "$SVG"
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated $ICNS"
