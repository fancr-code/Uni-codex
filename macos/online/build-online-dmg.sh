#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?output directory required}"
CODEX_PLUS_ARM_DMG="${2:?arm64 Codex++ DMG required}"
CODEX_PLUS_X64_DMG="${3:?x64 Codex++ DMG required}"
STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uni-codex-dmg.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT

/bin/mkdir -p "$OUTPUT"
/bin/cp "$ROOT/install-unicodex.sh" "$STAGE/安装 Uni-codex.command"
/bin/mkdir -p "$STAGE/codex-plus-plus"
/bin/cp "$CODEX_PLUS_ARM_DMG" "$STAGE/codex-plus-plus/CodexPlusPlus-arm64.dmg"
/bin/cp "$CODEX_PLUS_X64_DMG" "$STAGE/codex-plus-plus/CodexPlusPlus-x64.dmg"
/bin/cp "$ROOT/../../scripts/install-skill-collections.sh" "$STAGE/install-skill-collections.sh"
/bin/mkdir -p "$STAGE/skills"
/bin/cp "$ROOT/../../skills/collections.json" "$STAGE/skills/collections.json"
/bin/chmod 755 "$STAGE/安装 Uni-codex.command"
/bin/chmod 755 "$STAGE/install-skill-collections.sh"
if [[ -f "$ROOT/../../LICENSE" ]]; then
  /usr/bin/ditto "$ROOT/../../LICENSE" "$STAGE/LICENSE.txt"
fi
/usr/bin/hdiutil create -quiet -volname 'Uni-codex Online Installer' \
  -srcfolder "$STAGE" -format UDZO "$OUTPUT/Uni-codex-macOS-Online.dmg"
(
  cd "$OUTPUT"
  /usr/bin/shasum -a 256 'Uni-codex-macOS-Online.dmg' > 'SHA256SUMS-macOS.txt'
)
