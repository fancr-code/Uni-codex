#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Resources/AppIcon"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codex-app-icon-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

fail() { printf 'app-icon-tests: FAIL: %s\n' "$1" >&2; exit 1; }
dimension() { /usr/bin/sips -g "$2" "$1" 2>/dev/null | /usr/bin/awk -F': ' -v key="$2" '$1 ~ key {print $2}'; }

[[ -f "$ROOT/scripts/generate-app-icon.swift" ]] || fail 'Swift icon renderer missing'
[[ -x "$ROOT/scripts/generate-app-icon.sh" ]] || fail 'icon generation wrapper missing or not executable'
/usr/bin/grep -Fq 'drawRadialGradient(' \
  "$ROOT/scripts/generate-app-icon.swift" \
  || fail 'top glow must use a borderless radial fade'
[[ -f "$ASSETS/AppIcon-1024.png" ]] || fail '1024 master missing'
[[ "$(dimension "$ASSETS/AppIcon-1024.png" pixelWidth)" == 1024 ]] || fail 'master width is not 1024'
[[ "$(dimension "$ASSETS/AppIcon-1024.png" pixelHeight)" == 1024 ]] || fail 'master height is not 1024'
[[ "$(dimension "$ASSETS/AppIcon-1024.png" hasAlpha)" == yes ]] || fail 'master has no alpha channel'

expected=$'icon_128x128.png\nicon_128x128@2x.png\nicon_16x16.png\nicon_16x16@2x.png\nicon_256x256.png\nicon_256x256@2x.png\nicon_32x32.png\nicon_32x32@2x.png\nicon_512x512.png\nicon_512x512@2x.png'
actual="$(find "$ASSETS/AppIcon.iconset" -maxdepth 1 -type f -name '*.png' -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual" == "$expected" ]] || fail 'iconset filenames differ from the standard ten-file set'

while IFS=$'\t' read -r name pixels; do
  file="$ASSETS/AppIcon.iconset/$name"
  [[ "$(dimension "$file" pixelWidth)" == "$pixels" && "$(dimension "$file" pixelHeight)" == "$pixels" ]] \
    || fail "wrong iconset dimensions: $name"
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

[[ -s "$ASSETS/AppIcon.icns" ]] || fail 'ICNS missing or empty'
/usr/bin/iconutil -c iconset -o "$OUT/decoded.iconset" "$ASSETS/AppIcon.icns" || fail 'ICNS cannot be decoded'
[[ -s "$ASSETS/provenance.md" ]] || fail 'icon provenance missing'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Info.plist" 2>/dev/null || true)" == AppIcon ]] \
  || fail 'Info.plist does not declare AppIcon'
rg -Fq '/bin/cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"' "$ROOT/build-codex-one-click-installer.sh" \
  || fail 'build does not copy AppIcon.icns'
rg -Fq 'CFBundleIconFile' "$ROOT/scripts/verify-release-artifact.sh" \
  || fail 'release verifier does not check the icon declaration'
rg -Fq 'Resources/AppIcon/AppIcon.icns' "$ROOT/scripts/verify-release-artifact.sh" \
  || fail 'release verifier does not compare the bundled icon with the approved asset'
printf 'app-icon-tests: PASS\n'
