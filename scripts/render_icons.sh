#!/usr/bin/env bash
set -euo pipefail

# Re-renders all source SVG park/attraction icons in Resources/parks/ to 96x96 transparent PNGs.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARKS_DIR="$SCRIPT_DIR/../Sources/MeuralSyncCore/Resources/parks"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

count=0
for svg in "$PARKS_DIR"/*.svg; do
    [ -f "$svg" ] || continue
    png="${svg%.svg}.png"
    rsvg-convert -w 96 -h 96 -o "$png" "$svg"
    count=$((count + 1))
done

echo "Rendered $count PNG icon(s) from SVG sources in $PARKS_DIR"
