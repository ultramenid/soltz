#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Rebuilds App/Icon/AppIcon.icns, the icon a build without full Xcode ships, from logo-dark.svg.
# It is the dark tile on purpose: from one picture macOS can only draw a dark tile well in every icon style (dark
# in Default and Dark, glass with a bright glyph in Clear and Tinted); a light tile stays a white square in all of
# them. The light icon needs the layered AppIcon.icon, which only actool compiles (see bundle-app.sh).
set -eu
icon="$(cd "$(dirname "$0")/../App/Icon" && pwd)"
set="$(mktemp -d)/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$icon/logo-dark.svg" --out "$set/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z "$((size * 2))" "$((size * 2))" "$icon/logo-dark.svg" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$icon/AppIcon.icns"
echo "Wrote $icon/AppIcon.icns"
