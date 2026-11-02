#!/usr/bin/env bash
# Regenerates Support/AppIcon.icns from scripts/icon.swift. Only needed after changing the drawing.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"

swift scripts/icon.swift "$work/icon_1024.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/icon_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Support/AppIcon.icns
echo "Wrote Support/AppIcon.icns"
