#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
  printf 'verify-release-artifact: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 || "$#" == 4 ]] \
  || die "usage: $0 /path/to/Codex-一键安装.dmg [--require-hardware-attestations arm64.json x86_64.json]"
DMG="$1"
REQUIRE_HARDWARE_ATTESTATIONS=false
ARM64_ATTESTATION=''
X86_64_ATTESTATION=''
if [[ "$#" == 4 ]]; then
  [[ "$2" == --require-hardware-attestations ]] \
    || die 'unknown release verification option'
  REQUIRE_HARDWARE_ATTESTATIONS=true
  ARM64_ATTESTATION="$3"
  X86_64_ATTESTATION="$4"
fi
[[ -f "$DMG" ]] || die "DMG does not exist: $DMG"
[[ "$(/usr/bin/basename "$DMG")" == 'Codex-一键安装.dmg' ]] \
  || die 'artifact name must be Codex-一键安装.dmg'
command -v jq >/dev/null 2>&1 || die 'jq is required'

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-release-verify.XXXXXX")"
ATTACH_PLIST="$TEMP_ROOT/attach.plist"
MOUNT_POINT=''
cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
      || /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 \
      || true
  fi
  /bin/rm -R "$TEMP_ROOT"
}
trap cleanup EXIT

/usr/bin/hdiutil verify "$DMG" >/dev/null || die 'hdiutil verification failed'
/usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$DMG" > "$ATTACH_PLIST" \
  || die 'unable to mount DMG'

index=0
while [[ "$index" -lt 32 ]]; do
  MOUNT_POINT="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$ATTACH_PLIST" 2>/dev/null || true)"
  [[ -n "$MOUNT_POINT" ]] && break
  index=$((index + 1))
done
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die 'unable to resolve DMG mount point'

expected_entries="$TEMP_ROOT/expected-entries"
actual_entries="$TEMP_ROOT/actual-entries"
printf '%s\n' \
  'Applications' \
  'Codex 一键安装.app' \
  '小白安装说明.html' \
  '开始安装前请看.txt' \
  '第三方许可与源码' \
  | LC_ALL=C /usr/bin/sort > "$expected_entries"
/usr/bin/find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; \
  | LC_ALL=C /usr/bin/sort > "$actual_entries"
/usr/bin/cmp -s "$expected_entries" "$actual_entries" \
  || die 'DMG root layout contains missing or unexpected entries'

[[ -L "$MOUNT_POINT/Applications" \
   && "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == /Applications ]] \
  || die 'Applications link is invalid'
while IFS= read -r link; do
  [[ "$link" == "$MOUNT_POINT/Applications" ]] \
    || die "unexpected symbolic link: ${link#"$MOUNT_POINT"/}"
done < <(/usr/bin/find "$MOUNT_POINT" -type l -print)

APP="$MOUNT_POINT/Codex 一键安装.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE="$CONTENTS/MacOS/CodexOneClickInstaller"
HELPER="$RESOURCES/installer-support"
CORE="$RESOURCES/installer-core.sh"
PAYLOAD_ROOT="$RESOURCES/offline-payloads"
MANIFEST="$PAYLOAD_ROOT/payload-manifest.json"
[[ -d "$APP" && -x "$EXECUTABLE" && -x "$HELPER" && -x "$CORE" && -f "$MANIFEST" ]] \
  || die 'installer app is incomplete'

validate_payload_filesystem() {
  local payload_root="$1"
  local directory file entry relative
  [[ -d "$payload_root" && ! -L "$payload_root" ]] \
    || die 'offline payload root is not a regular directory'
  for directory in apps metadata plugins script-market sources; do
    [[ -d "$payload_root/$directory" && ! -L "$payload_root/$directory" ]] \
      || die "offline payload filesystem entry is not a regular directory: $directory"
  done
  for file in model-catalog.json payload-manifest.json plugin-catalog.json; do
    [[ -f "$payload_root/$file" && ! -L "$payload_root/$file" ]] \
      || die "offline payload filesystem entry is not a regular file: $file"
  done
  if ! /usr/bin/find "$payload_root" -mindepth 1 -maxdepth 1 -print0 | \
    while IFS= read -r -d '' entry; do
      relative="${entry#"$payload_root"/}"
      case "$relative" in
        apps|metadata|plugins|script-market|sources|model-catalog.json|payload-manifest.json|plugin-catalog.json) ;;
        *) die "offline payload filesystem contains unexpected entry: $relative" ;;
      esac
    done; then
    exit 1
  fi
  if ! /usr/bin/find "$payload_root/metadata" -mindepth 1 -maxdepth 1 -print0 | \
    while IFS= read -r -d '' entry; do
      relative="${entry#"$payload_root"/}"
      die "offline payload filesystem contains unexpected entry: $relative"
    done; then
    exit 1
  fi
}
validate_payload_filesystem "$PAYLOAD_ROOT"

ROOT_MODEL_CATALOG="$RESOURCES/model-catalog.json"
OFFLINE_MODEL_CATALOG="$PAYLOAD_ROOT/model-catalog.json"
[[ -f "$ROOT_MODEL_CATALOG" && -f "$OFFLINE_MODEL_CATALOG" ]] \
  || die 'bundled model catalog is missing'
/usr/bin/cmp -s "$ROOT_MODEL_CATALOG" "$OFFLINE_MODEL_CATALOG" \
  || die 'bundled model catalog differs from offline payload'
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null || die 'Info.plist is invalid'
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS/Info.plist" 2>/dev/null || true)"
[[ "$ICON_NAME" == AppIcon ]] || die 'Info.plist does not declare AppIcon'
ICON_FILE="$RESOURCES/AppIcon.icns"
[[ -s "$ICON_FILE" ]] || die 'AppIcon.icns is missing from the installer app'
/usr/bin/sips -g format "$ICON_FILE" 2>/dev/null | /usr/bin/grep -q 'format: icns' \
  || die 'AppIcon.icns is unreadable'
/usr/bin/cmp -s "$ROOT/Resources/AppIcon/AppIcon.icns" "$ICON_FILE" \
  || die 'bundled AppIcon.icns differs from the approved asset'
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  || die 'installer app signature verification failed'

architectures="$(/usr/bin/lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] \
  || die 'installer GUI is not universal arm64/x86_64'
helper_architectures="$(/usr/bin/lipo -archs "$HELPER" 2>/dev/null || true)"
if [[ "${TEST_MODE:-0}" != 1 ]]; then
  [[ " $helper_architectures " == *' arm64 '* && " $helper_architectures " == *' x86_64 '* ]] \
    || die 'installer helper is not universal arm64/x86_64'
fi

"$HELPER" manifest-validate "$MANIFEST" >/dev/null \
  || die 'payload manifest validation failed'
payload_count="$(jq -er '.files | length' "$MANIFEST")"
[[ "$payload_count" =~ ^[0-9]+$ && "$payload_count" -gt 0 ]] \
  || die 'payload manifest is empty'

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print tolower($1)}'
}

while IFS=$'\t' read -r identifier relative expected; do
  [[ "$relative" != /* \
     && "$relative" != *'..'* \
     && "$relative" != *'\\'* \
     && "$relative" != *$'\n'* ]] || die "unsafe payload path: $identifier"
  case "$identifier" in
    plugin-marketplaces)
      target="$PAYLOAD_ROOT/plugins/file-manifest.json"
      ;;
    script-market)
      target="$PAYLOAD_ROOT/script-market/index.json"
      ;;
    *)
      target="$PAYLOAD_ROOT/$relative"
      ;;
  esac
  [[ -f "$target" ]] || die "payload file is missing: $identifier"
  actual="$(sha256_file "$target")"
  [[ "$actual" == "$(printf '%s' "$expected" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]] \
    || die "payload hash mismatch: $identifier"
done < <(jq -er '.files[] | [.id,.relativePath,.sha256] | @tsv' "$MANIFEST")

PLUGIN_CATALOG="$PAYLOAD_ROOT/plugin-catalog.json"
PLUGIN_MANIFEST="$PAYLOAD_ROOT/plugins/file-manifest.json"
[[ -f "$PLUGIN_CATALOG" && -f "$PLUGIN_MANIFEST" ]] \
  || die 'offline plugin metadata is missing'
"$HELPER" plugin-package-validate \
  --root "$PAYLOAD_ROOT/plugins" \
  --catalog "$PLUGIN_CATALOG" >/dev/null \
  || die 'plugin package validation failed'

[[ -s "$MOUNT_POINT/开始安装前请看.txt" \
   && -s "$MOUNT_POINT/小白安装说明.html" \
   && -s "$MOUNT_POINT/第三方许可与源码/AGPL-3.0.txt" \
   && -s "$MOUNT_POINT/第三方许可与源码/第三方许可说明.md" ]] \
  || die 'guides or legal notices are incomplete'

if [[ "${TEST_MODE:-0}" != 1 ]]; then
  jq -e '
    ([.files[].id] | sort) == ([
      "chatgpt-codex-arm64", "chatgpt-codex-x86_64",
      "codex-plus-plus-arm64", "codex-plus-plus-source",
      "codex-plus-plus-x86_64", "model-catalog", "plugin-marketplaces",
      "script-market"
    ] | sort) and
    (.files[] | select(.id == "chatgpt-codex-arm64") | .architecture) == "arm64" and
    (.files[] | select(.id == "chatgpt-codex-x86_64") | .architecture) == "x86_64" and
    (.files[] | select(.id == "codex-plus-plus-arm64") | .architecture) == "arm64" and
    (.files[] | select(.id == "codex-plus-plus-x86_64") | .architecture) == "x86_64" and
    ([.files[] | select(
      .id == "codex-plus-plus-arm64" or
      .id == "codex-plus-plus-x86_64" or
      .id == "codex-plus-plus-source"
    )] | all(
      .version == "1.2.43" and
      .compatibilityRevision == "cross-provider-content-v1"
    ))
  ' "$MANIFEST" >/dev/null || die 'required product payload set is invalid'

  jq -e '
    ([.plugins[] | "\(.id)@\(.marketplace)"] | sort) == ([
      "browser@openai-bundled", "chrome@openai-bundled",
      "computer-use@openai-bundled", "latex@openai-bundled",
      "pdf@openai-primary-runtime", "documents@openai-primary-runtime",
      "spreadsheets@openai-primary-runtime", "presentations@openai-primary-runtime",
      "github@openai-curated"
    ] | sort)
  ' "$PLUGIN_CATALOG" >/dev/null || die 'offline plugin catalog is not the approved nine-plugin set'
  while IFS=$'\t' read -r relative expected; do
    [[ "$relative" != /* && "$relative" != *'..'* && "$relative" != *'\\'* ]] \
      || die 'unsafe plugin manifest path'
    plugin_file="$PAYLOAD_ROOT/plugins/$relative"
    [[ -f "$plugin_file" ]] || die "plugin payload is missing: $relative"
    [[ "$(sha256_file "$plugin_file")" == "$expected" ]] \
      || die "plugin payload hash mismatch: $relative"
  done < <(jq -er '.files[] | [.path,(.sha256 | ascii_downcase)] | @tsv' "$PLUGIN_MANIFEST")

  SCRIPT_INDEX="$PAYLOAD_ROOT/script-market/index.json"
  jq -e '(.scripts | type == "array" and length > 0)' "$SCRIPT_INDEX" >/dev/null \
    || die 'script market index is empty'
  while IFS=$'\t' read -r identifier expected; do
    [[ "$identifier" =~ ^[A-Za-z0-9_-]+$ ]] || die 'unsafe script identifier'
    script_file="$PAYLOAD_ROOT/script-market/scripts/$identifier.js"
    [[ -f "$script_file" ]] || die "script payload is missing: $identifier"
    [[ "$(sha256_file "$script_file")" == "$expected" ]] \
      || die "script payload hash mismatch: $identifier"
  done < <(jq -er '.scripts[] | [.id,(.sha256 | ascii_downcase)] | @tsv' "$SCRIPT_INDEX")

  source_relative="$(jq -er '.files[] | select(.id == "codex-plus-plus-source") | .relativePath' "$MANIFEST")"
  [[ -f "$PAYLOAD_ROOT/$source_relative" \
     && -f "$MOUNT_POINT/第三方许可与源码/$(/usr/bin/basename "$source_relative")" ]] \
    || die 'version-matched Codex++ source archive is missing from the legal bundle'
  source_provenance_member="$(/usr/bin/tar -tzf "$PAYLOAD_ROOT/$source_relative" \
    | /usr/bin/awk '/\/CODEXKIT-PATCH\.md$/ {print; exit}')"
  [[ -n "$source_provenance_member" \
     && -s "$RESOURCES/CodexPlusPlus-Compatibility/CODEXKIT-PATCH.md" \
     && -s "$RESOURCES/CodexPlusPlus-Compatibility/v1.2.43-cross-provider-history.patch" \
     && -s "$MOUNT_POINT/第三方许可与源码/CODEXKIT-PATCH.md" \
     && -s "$MOUNT_POINT/第三方许可与源码/v1.2.43-cross-provider-history.patch" ]] \
    || die 'Codex++ compatibility provenance is incomplete'
  /usr/bin/cmp -s \
    "$ROOT/patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch" \
    "$RESOURCES/CodexPlusPlus-Compatibility/v1.2.43-cross-provider-history.patch" \
    || die 'bundled Codex++ compatibility patch differs from the approved patch'
  [[ "$(/usr/bin/wc -c < "$MOUNT_POINT/第三方许可与源码/AGPL-3.0.txt" | /usr/bin/tr -d ' ')" -gt 20000 ]] \
    || die 'full AGPL-3.0 license text is missing'
fi

notarized=false
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  notarized=true
fi
hardware_attested=false
if [[ "$REQUIRE_HARDWARE_ATTESTATIONS" == true ]]; then
  bash "$ROOT/scripts/verify-hardware-attestations.sh" \
    "$DMG" "$ARM64_ATTESTATION" "$X86_64_ATTESTATION" >/dev/null \
    || die 'hardware attestation verification failed'
  hardware_attested=true
fi
printf '{"status":"pass","dmg":"%s","architectures":["arm64","x86_64"],"notarized":%s,"payloadCount":%s,"hardwareAttested":%s}\n' \
  "$(/usr/bin/basename "$DMG")" "$notarized" "$payload_count" "$hardware_attested"
