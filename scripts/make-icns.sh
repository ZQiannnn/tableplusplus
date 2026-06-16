#!/bin/bash
# Render the app icon and build scripts/AppIcon.icns.
# The .icns is committed so CI/package.sh need not re-render.
#
# Usage: ./scripts/make-icns.sh

set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ rendering 1024px master"
ICON_OUT="$TMP/icon_1024.png" swift scripts/render-icon.swift

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

gen() { # size filename
  sips -z "$1" "$1" "$TMP/icon_1024.png" --out "$ICONSET/$2" >/dev/null
}

echo "→ scaling iconset"
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$TMP/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

echo "→ iconutil → scripts/AppIcon.icns"
iconutil -c icns "$ICONSET" -o scripts/AppIcon.icns
echo "✓ scripts/AppIcon.icns ($(du -h scripts/AppIcon.icns | cut -f1))"
