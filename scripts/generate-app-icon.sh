#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Resources/AppIcon"
ICONSET="$ASSETS/AppIcon.iconset"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-app-icon-build.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

dimension() {
  /usr/bin/sips -g "$2" "$1" 2>/dev/null \
    | /usr/bin/awk -F': ' -v key="$2" '$1 ~ key {print $2}'
}

/usr/bin/xcrun swiftc -O -framework AppKit \
  "$ROOT/scripts/generate-app-icon.swift" \
  -o "$TEMP_ROOT/generate-app-icon"
/bin/mkdir -p "$ASSETS"
"$TEMP_ROOT/generate-app-icon" "$ASSETS/AppIcon-1024.png"
[[ "$(dimension "$ASSETS/AppIcon-1024.png" pixelWidth)" == 1024 ]]
[[ "$(dimension "$ASSETS/AppIcon-1024.png" pixelHeight)" == 1024 ]]
[[ "$(dimension "$ASSETS/AppIcon-1024.png" hasAlpha)" == yes ]]

/bin/rm -R "$ICONSET" 2>/dev/null || true
/bin/mkdir -p "$ICONSET"
while IFS=$'\t' read -r name pixels; do
  /usr/bin/sips -z "$pixels" "$pixels" \
    "$ASSETS/AppIcon-1024.png" \
    --out "$ICONSET/$name" >/dev/null
  [[ "$(dimension "$ICONSET/$name" pixelWidth)" == "$pixels" ]]
  [[ "$(dimension "$ICONSET/$name" pixelHeight)" == "$pixels" ]]
done <<'SIZES'
icon_16x16.png	16
icon_16x16@2x.png	32
icon_32x32.png	32
icon_32x32@2x.png	64
icon_128x128.png	128
icon_128x128@2x.png	256
icon_256x256.png	256
icon_256x256@2x.png	512
icon_512x512.png	512
icon_512x512@2x.png	1024
SIZES

/bin/rm -f "$ASSETS/AppIcon.icns"
/usr/bin/iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
[[ -s "$ASSETS/AppIcon.icns" ]]
