#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT_OVERRIDE:-$ROOT/build}"
DIST_ROOT="$ROOT/dist"
APP="$BUILD_ROOT/Codex 一键安装.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
PAYLOAD_ROOT="${PAYLOAD_ROOT_OVERRIDE:-$ROOT/vendor/offline-payloads}"
DMG_STAGE="$BUILD_ROOT/dmg-stage"
DMG="$DIST_ROOT/Codex-一键安装.dmg"
NOTARY_RESULT="$BUILD_ROOT/notary-result.json"
STATUS_FILE="$DIST_ROOT/artifact-status.json"
CHECKSUMS_FILE="$DIST_ROOT/SHA256SUMS.txt"
DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-}"
ICON_MASTER="$ROOT/Resources/AppIcon/AppIcon-1024.png"
ICON_FILE="$ROOT/Resources/AppIcon/AppIcon.icns"
CODEX_PLUS_VERSION='1.2.44'
CODEX_PLUS_COMPATIBILITY_REVISION='cross-provider-content-v1'
CODEX_PLUS_PATCH="$ROOT/patches/CodexPlusPlus/v1.2.44-cross-provider-history.patch"

die() {
  printf 'build-codex-one-click-installer: %s\n' "$*" >&2
  exit 1
}

case "$BUILD_ROOT" in
  /*) ;;
  *) die "BUILD_ROOT_OVERRIDE must be an absolute path" ;;
esac
[[ "$BUILD_ROOT" != / && "$BUILD_ROOT" != "$ROOT" && ! -L "$BUILD_ROOT" ]] \
  || die "BUILD_ROOT_OVERRIDE is unsafe"

command -v jq >/dev/null 2>&1 || die "jq is required"

validate_payload_filesystem() {
  local payload_root="$1"
  local directory file entry relative
  [[ -d "$payload_root" && ! -L "$payload_root" ]] \
    || die "offline payload root is not a regular directory"
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

[[ -f "$PAYLOAD_ROOT/payload-manifest.json" ]] \
  || die "offline payloads are missing; run scripts/refresh-offline-payloads.sh first"
[[ -f "$PAYLOAD_ROOT/model-catalog.json" \
   && -f "$PAYLOAD_ROOT/plugin-catalog.json" \
   && -f "$PAYLOAD_ROOT/script-market/index.json" \
   && -f "$PAYLOAD_ROOT/plugins/file-manifest.json" ]] \
  || die "offline payload snapshot is incomplete"
jq -e '
  (.scripts | map({key: .id, value: .version}) | from_entries) as $versions |
  $versions["codex-context-used-meter"] == "101" and
  $versions["codex-token-usage"] == "0.1.7" and
  $versions["codex-daily-token-usage"] == "1.4.13" and
  $versions["codex-live-token-cost"] == "0.7.2"
' "$PAYLOAD_ROOT/script-market/index.json" >/dev/null \
  || die "offline script market is missing approved monitor versions"
[[ -f "$ICON_MASTER" && -s "$ICON_FILE" ]] \
  || die "AppIcon assets are missing; run scripts/generate-app-icon.sh"
[[ "$(/usr/bin/sips -g pixelWidth "$ICON_MASTER" | /usr/bin/awk '/pixelWidth/ {print $2}')" == 1024 \
   && "$(/usr/bin/sips -g pixelHeight "$ICON_MASTER" | /usr/bin/awk '/pixelHeight/ {print $2}')" == 1024 \
   && "$(/usr/bin/sips -g hasAlpha "$ICON_MASTER" | /usr/bin/awk '/hasAlpha/ {print $2}')" == yes ]] \
  || die "AppIcon master must be a 1024x1024 PNG with alpha"
/usr/bin/sips -g format "$ICON_FILE" 2>/dev/null | /usr/bin/grep -q 'format: icns' \
  || die "AppIcon.icns is unreadable"
/usr/bin/cmp -s "$ROOT/Resources/model-catalog.json" "$PAYLOAD_ROOT/model-catalog.json" \
  || die "source model catalog differs from frozen offline payload"
[[ -f "$CODEX_PLUS_PATCH" && ! -L "$CODEX_PLUS_PATCH" ]] \
  || die "Codex++ compatibility patch is missing"
jq -e \
  --arg version "$CODEX_PLUS_VERSION" \
  --arg revision "$CODEX_PLUS_COMPATIBILITY_REVISION" '
    [.files[] | select(
      .id == "codex-plus-plus-arm64" or
      .id == "codex-plus-plus-x86_64" or
      .id == "codex-plus-plus-source"
    )] as $payloads |
    ($payloads | length) == 3 and
    all($payloads[]; .version == $version and .compatibilityRevision == $revision)
  ' "$PAYLOAD_ROOT/payload-manifest.json" >/dev/null \
  || die "Codex++ payload set is not the approved compatibility revision"
source_relative="$(jq -er \
  '.files[] | select(.id == "codex-plus-plus-source") | .relativePath' \
  "$PAYLOAD_ROOT/payload-manifest.json")"
source_archive="$PAYLOAD_ROOT/$source_relative"
[[ -f "$source_archive" && ! -L "$source_archive" ]] \
  || die "version-matched Codex++ source archive is missing"
codex_plus_provenance_member="$(/usr/bin/tar -tzf "$source_archive" \
  | /usr/bin/awk '/\/CODEXKIT-PATCH\.md$/ {print; exit}')"
[[ -n "$codex_plus_provenance_member" ]] \
  || die "Codex++ patched source provenance is missing"

/bin/rm -R "$BUILD_ROOT" 2>/dev/null || true
/bin/mkdir -p "$BUILD_ROOT/bin/arm64" "$BUILD_ROOT/bin/x86_64" "$MACOS_DIR" "$RESOURCES_DIR" "$DIST_ROOT"
/bin/rm -f "$DMG" "$STATUS_FILE" "$CHECKSUMS_FILE"

compile_support() {
  local architecture="$1"
  local target="$2"
  local output="$BUILD_ROOT/bin/$architecture/installer-support"
  xcrun swiftc \
    -O \
    -target "$target" \
    -framework Foundation \
    -framework CryptoKit \
    "$ROOT/Sources/InstallerDomain.swift" \
    "$ROOT/Sources/TomlDocument.swift" \
    "$ROOT/Sources/ManagedPathPolicy.swift" \
    "$ROOT/Sources/InstallerBackup.swift" \
    "$ROOT/Sources/InstallExpectation.swift" \
    "$ROOT/Sources/InstallerConfiguration.swift" \
    "$ROOT/Sources/ProviderCatalog.swift" \
    "$ROOT/Sources/ScriptMarketInstaller.swift" \
    "$ROOT/Sources/InstallerSupportCLI.swift" \
    -o "$output"
}

compile_gui() {
  local architecture="$1"
  local target="$2"
  local output="$BUILD_ROOT/bin/$architecture/CodexOneClickInstaller"
  xcrun swiftc \
    -O \
    -target "$target" \
    -framework Cocoa \
    -framework CryptoKit \
    -framework Security \
    "$ROOT/Sources/InstallerDomain.swift" \
    "$ROOT/Sources/ProviderCatalog.swift" \
    "$ROOT/Sources/InstallerState.swift" \
    "$ROOT/Sources/OpenAIAuthorization.swift" \
    "$ROOT/Sources/CodexOneClickInstaller.swift" \
    -o "$output"
}

compile_support arm64 arm64-apple-macos14.0
compile_support x86_64 x86_64-apple-macos14.0
compile_gui arm64 arm64-apple-macos14.0
compile_gui x86_64 x86_64-apple-macos14.0

/usr/bin/lipo -create \
  "$BUILD_ROOT/bin/arm64/installer-support" \
  "$BUILD_ROOT/bin/x86_64/installer-support" \
  -output "$RESOURCES_DIR/installer-support"
/usr/bin/lipo -create \
  "$BUILD_ROOT/bin/arm64/CodexOneClickInstaller" \
  "$BUILD_ROOT/bin/x86_64/CodexOneClickInstaller" \
  -output "$MACOS_DIR/CodexOneClickInstaller"

/bin/cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS/Info.plist")" == AppIcon ]] \
  || die "Info.plist must declare AppIcon"
/bin/cp -cR "$PAYLOAD_ROOT" "$RESOURCES_DIR/offline-payloads" \
  || die "unable to clone offline payloads into the app bundle"
/bin/cp "$ROOT/Resources/installer-core.sh" "$RESOURCES_DIR/installer-core.sh"
/bin/cp "$ROOT/scripts/install-skill-collections.sh" "$RESOURCES_DIR/install-skill-collections.sh"
/bin/cp "$ROOT/skills/collections.json" "$RESOURCES_DIR/skill-collections.json"
UNICODEX_SKILL_MANIFEST="$ROOT/skills/collections.json" \
  UNICODEX_SKILL_DESTINATION="$RESOURCES_DIR/skill-collections" \
  UNICODEX_SKILL_PREPARE_BUNDLE=1 \
  "$ROOT/scripts/install-skill-collections.sh"
/bin/cp "$PAYLOAD_ROOT/model-catalog.json" "$RESOURCES_DIR/model-catalog.json"
/bin/cp "$ROOT/Resources/plugin-catalog.json" "$RESOURCES_DIR/plugin-catalog.json"
/bin/mkdir -p "$RESOURCES_DIR/CodexPlusPlus-Compatibility"
/bin/cp "$CODEX_PLUS_PATCH" \
  "$RESOURCES_DIR/CodexPlusPlus-Compatibility/v1.2.44-cross-provider-history.patch"
/usr/bin/tar -xOzf "$source_archive" "$codex_plus_provenance_member" \
  > "$RESOURCES_DIR/CodexPlusPlus-Compatibility/CODEXKIT-PATCH.md"
/usr/bin/ditto "$ROOT/Resources/guides" "$RESOURCES_DIR/guides"
/usr/bin/ditto "$ROOT/Resources/licenses" "$RESOURCES_DIR/licenses"
/bin/chmod 755 "$MACOS_DIR/CodexOneClickInstaller" "$RESOURCES_DIR/installer-support" "$RESOURCES_DIR/installer-core.sh" "$RESOURCES_DIR/install-skill-collections.sh"
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

architectures="$(/usr/bin/lipo -archs "$MACOS_DIR/CodexOneClickInstaller")"
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] \
  || die "installer GUI is not universal"
support_architectures="$(/usr/bin/lipo -archs "$RESOURCES_DIR/installer-support")"
[[ " $support_architectures " == *' arm64 '* && " $support_architectures " == *' x86_64 '* ]] \
  || die "installer helper is not universal"
"$RESOURCES_DIR/installer-support" manifest-validate \
  "$RESOURCES_DIR/offline-payloads/payload-manifest.json" >/dev/null

# Apple QA1940 requires clearing extended attributes from the complete bundle
# before signing. Some frozen marketplace Git packs are intentionally read-only,
# so make only this disposable build copy owner-writable first. codesign then
# seals every resulting resource.
/bin/chmod -R u+w "$APP" \
  || die "unable to prepare the installer app for metadata sanitization"
/usr/bin/xattr -cr "$APP" \
  || die "unable to sanitize installer app extended attributes"

if [[ -z "$DEVELOPER_ID" && "${ADHOC_ONLY:-0}" != 1 ]]; then
  DEVELOPER_ID="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | /usr/bin/head -n 1)"
fi

SIGNING_MODE='ad-hoc signed'
NOTARIZED=false
if [[ -n "$DEVELOPER_ID" ]]; then
  [[ "$DEVELOPER_ID" == Developer\ ID\ Application:* ]] \
    || die "DEVELOPER_ID_APPLICATION must name a Developer ID Application identity"
  [[ -n "${NOTARYTOOL_PROFILE:-}" ]] \
    || die "NOTARYTOOL_PROFILE is required when a Developer ID Application identity is available"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$RESOURCES_DIR/installer-support"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$MACOS_DIR/CodexOneClickInstaller"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  SIGNING_MODE='Developer ID + notarized'
else
  /usr/bin/codesign --force --sign - "$RESOURCES_DIR/installer-support"
  /usr/bin/codesign --force --sign - "$MACOS_DIR/CodexOneClickInstaller"
  /usr/bin/codesign --force --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

/bin/rm -R "$DMG_STAGE" 2>/dev/null || true
/bin/mkdir -p "$DMG_STAGE/第三方许可与源码"
/bin/cp -cR "$APP" "$DMG_STAGE/Codex 一键安装.app" \
  || die "unable to clone the installer app into the DMG stage"
/bin/cp "$ROOT/Resources/guides/Open-Guide.zh-CN.txt" "$DMG_STAGE/开始安装前请看.txt"
/bin/cp "$ROOT/Resources/guides/Beginner-Guide.zh-CN.html" "$DMG_STAGE/小白安装说明.html"
/bin/cp "$ROOT/Resources/licenses/Third-Party-Notices.md" "$DMG_STAGE/第三方许可与源码/第三方许可说明.md"
ln -s /Applications "$DMG_STAGE/Applications"

/bin/cp "$source_archive" "$DMG_STAGE/第三方许可与源码/$(/usr/bin/basename "$source_archive")"
/bin/cp "$CODEX_PLUS_PATCH" \
  "$DMG_STAGE/第三方许可与源码/v1.2.44-cross-provider-history.patch"
/usr/bin/tar -xOzf "$source_archive" "$codex_plus_provenance_member" \
  > "$DMG_STAGE/第三方许可与源码/CODEXKIT-PATCH.md"
license_member="$(/usr/bin/tar -tzf "$source_archive" | /usr/bin/awk '/\/(LICENSE|COPYING)(\.[A-Za-z0-9_-]+)?$/ {print; exit}')"
[[ -n "$license_member" ]] || die "Codex++ source archive does not contain a license file"
/usr/bin/tar -xOzf "$source_archive" "$license_member" > "$DMG_STAGE/第三方许可与源码/AGPL-3.0.txt"
[[ -s "$DMG_STAGE/第三方许可与源码/AGPL-3.0.txt" ]] || die "Codex++ AGPL license extraction failed"

{
  printf '\n## 构建时冻结的插件清单\n\n'
  while IFS=$'\t' read -r marketplace plugin; do
    plugin_json="$(/usr/bin/find "$PAYLOAD_ROOT/plugins/cache/$marketplace/$plugin" -path '*/.codex-plugin/plugin.json' -type f -print -quit)"
    [[ -n "$plugin_json" ]] || die "plugin metadata missing while writing notices: $plugin@$marketplace"
    plugin_version="$(jq -er '.version' "$plugin_json")"
    plugin_license="$(jq -r '.license // .licenseID // "未声明"' "$plugin_json")"
    plugin_source="$(jq -r '.homepage // .repository // "由离线 marketplace.json 声明"' "$plugin_json")"
    printf -- '- `%s@%s`，版本 `%s`，来源：%s，许可证：%s\n' \
      "$plugin" "$marketplace" "$plugin_version" "$plugin_source" "$plugin_license"
  done < <(jq -r '.plugins[] | [.marketplace,.id] | @tsv' "$PAYLOAD_ROOT/plugin-catalog.json")
  printf '\n## 构建时冻结的脚本市场清单\n\n'
  jq -r '.scripts[] | "- `\(.id)`（\(.name)），版本 `\(.version)`，脚本：\(.script_url)，主页：\(.homepage // "未声明")，许可证：\(.license // "未声明")"' \
    "$PAYLOAD_ROOT/script-market/index.json"
} >> "$DMG_STAGE/第三方许可与源码/第三方许可说明.md"

if [[ -z "$DEVELOPER_ID" ]]; then
  [[ -s "$DMG_STAGE/开始安装前请看.txt" ]] \
    || die "ad-hoc builds must include Open-Guide.zh-CN.txt"
fi

/usr/bin/hdiutil create \
  -quiet \
  -volname 'Codex 一键安装' \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  "$DMG"

if [[ -n "$DEVELOPER_ID" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait \
    --output-format json > "$NOTARY_RESULT"
  [[ "$(jq -r '.status' "$NOTARY_RESULT")" == Accepted ]] \
    || die "notarytool did not accept the DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  NOTARIZED=true
fi

(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$(/usr/bin/basename "$DMG")" > "$(/usr/bin/basename "$CHECKSUMS_FILE")"
)

jq -n \
  --arg signing "$SIGNING_MODE" \
  --arg dmg "$DMG" \
  --argjson notarized "$NOTARIZED" \
  '{signing:$signing,notarized:$notarized,dmg:$dmg}' > "$STATUS_FILE"

printf 'build-codex-one-click-installer: %s\n' "$SIGNING_MODE"
printf 'build-codex-one-click-installer: %s\n' "$DMG"
