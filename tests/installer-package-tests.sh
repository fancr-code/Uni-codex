#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codex-installer-package-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

fail() {
  printf 'installer-package-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

BUILD_SCRIPT="$ROOT/build-codex-one-click-installer.sh"
[[ -f "$BUILD_SCRIPT" ]] || fail 'missing build-codex-one-click-installer.sh'
for contract in \
  'arm64-apple-macos14.0' \
  'x86_64-apple-macos14.0' \
  'lipo -create' \
  'Developer ID Application' \
  'notarytool' \
  'stapler' \
  'hdiutil create' \
  'Codex-一键安装.dmg' \
  'SHA256SUMS.txt' \
  'shasum -a 256' \
  'cross-provider-content-v1' \
  'v1.2.43-cross-provider-history.patch' \
  'CODEXKIT-PATCH.md' \
  '/bin/chmod -R u+w "$APP"' \
  '/usr/bin/xattr -cr "$APP"' \
  'unable to sanitize installer app extended attributes' \
  'BUILD_ROOT_OVERRIDE must be an absolute path' \
  'BUILD_ROOT_OVERRIDE is unsafe'; do
  rg -Fq "$contract" "$BUILD_SCRIPT" || fail "build contract missing: $contract"
done

VERIFY_SCRIPT="$ROOT/scripts/verify-release-artifact.sh"
[[ -f "$VERIFY_SCRIPT" ]] || fail 'missing scripts/verify-release-artifact.sh'
for contract in \
  '.version == "1.2.43"' \
  'v1.2.43-cross-provider-history.patch'; do
  rg -Fq "$contract" "$VERIFY_SCRIPT" || fail "release verifier contract missing: $contract"
done
! rg -Fq 'v1.2.42-cross-provider-history.patch' "$VERIFY_SCRIPT" \
  || fail 'release verifier still accepts the v1.2.42 patch'

BUILD_BOUNDARY_ROOT="$OUT/build-boundary-project"
BUILD_BOUNDARY_PAYLOAD="$BUILD_BOUNDARY_ROOT/payload"
BUILD_BOUNDARY_BIN="$OUT/build-boundary-bin"
BUILD_BOUNDARY_LOG="$OUT/build-boundary.log"
BUILD_BOUNDARY_MARKER="$OUT/build-boundary-xcrun-called"
mkdir -p "$BUILD_BOUNDARY_ROOT/Resources/AppIcon" \
  "$BUILD_BOUNDARY_PAYLOAD/apps" \
  "$BUILD_BOUNDARY_PAYLOAD/metadata" \
  "$BUILD_BOUNDARY_PAYLOAD/plugins" \
  "$BUILD_BOUNDARY_PAYLOAD/script-market" \
  "$BUILD_BOUNDARY_PAYLOAD/sources" \
  "$BUILD_BOUNDARY_BIN"
cp "$BUILD_SCRIPT" "$BUILD_BOUNDARY_ROOT/build-codex-one-click-installer.sh"
cp "$ROOT/Resources/AppIcon/AppIcon-1024.png" "$BUILD_BOUNDARY_ROOT/Resources/AppIcon/AppIcon-1024.png"
cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$BUILD_BOUNDARY_ROOT/Resources/AppIcon/AppIcon.icns"
cp "$ROOT/Resources/model-catalog.json" "$BUILD_BOUNDARY_ROOT/Resources/model-catalog.json"
cp "$ROOT/Resources/model-catalog.json" "$BUILD_BOUNDARY_PAYLOAD/model-catalog.json"
printf '%s\n' '{"schemaVersion":1,"files":[]}' > "$BUILD_BOUNDARY_PAYLOAD/payload-manifest.json"
printf '%s\n' '{"schemaVersion":1,"plugins":[]}' > "$BUILD_BOUNDARY_PAYLOAD/plugin-catalog.json"
printf '%s\n' '{"schemaVersion":1,"files":[]}' > "$BUILD_BOUNDARY_PAYLOAD/plugins/file-manifest.json"
printf '%s\n' '{"version":1,"scripts":[]}' > "$BUILD_BOUNDARY_PAYLOAD/script-market/index.json"
printf '%s\n' 'not allowed at the payload root' > "$BUILD_BOUNDARY_PAYLOAD/unlisted-root.txt"
cat > "$BUILD_BOUNDARY_BIN/xcrun" <<SH
#!/usr/bin/env bash
printf '%s\n' called > "$BUILD_BOUNDARY_MARKER"
exit 88
SH
chmod +x "$BUILD_BOUNDARY_BIN/xcrun"
set +e
PATH="$BUILD_BOUNDARY_BIN:$PATH" \
PAYLOAD_ROOT_OVERRIDE="$BUILD_BOUNDARY_PAYLOAD" \
ADHOC_ONLY=1 \
bash "$BUILD_BOUNDARY_ROOT/build-codex-one-click-installer.sh" > "$BUILD_BOUNDARY_LOG" 2>&1
build_boundary_status=$?
set -e
build_boundary_failure=0
if [[ "$build_boundary_status" -eq 0 || -e "$BUILD_BOUNDARY_MARKER" ]]; then
  printf '%s\n' 'installer-package-tests: FAIL: build accepted an unlisted payload-root file' >&2
  build_boundary_failure=1
fi
if ! rg -Fq 'offline payload filesystem contains unexpected entry: unlisted-root.txt' "$BUILD_BOUNDARY_LOG"; then
  printf '%s\n' 'installer-package-tests: FAIL: build did not report the exact payload filesystem allowlist failure' >&2
  build_boundary_failure=1
fi

[[ -f "$ROOT/README.md" ]] || fail 'README missing'
[[ -f "$ROOT/Resources/guides/Beginner-Guide.zh-CN.html" ]] || fail 'beginner guide missing'
[[ -f "$ROOT/Resources/guides/Open-Guide.zh-CN.txt" ]] || fail 'open guide missing'
[[ -f "$ROOT/Resources/licenses/Third-Party-Notices.md" ]] || fail 'third-party notices missing'
! rg -n 'sk-[A-Za-z0-9._-]{8,}' "$ROOT/Resources/guides" >/dev/null || fail 'guide contains API-Key-like secret'

DOCUMENTATION=(
  "$ROOT/README.md"
  "$ROOT/Resources/guides/Beginner-Guide.zh-CN.html"
  "$ROOT/Resources/guides/Open-Guide.zh-CN.txt"
)
for document in "${DOCUMENTATION[@]}"; do
  rg -q '默认(使用)?纯 API' "$document" \
    || fail "documentation contract missing pure-API default in $(basename "$document")"
  for contract in \
    'DeepSeek' \
    'Kimi 开放平台' \
    'Kimi Code' \
    '智谱 GLM' \
    '阿里千问' \
    'Xiaomi MiMo' \
    '所选服务商' \
    '上游模型' \
    '离线快照' \
    '获取 OpenAI 授权' \
    '授权不等于 GPT API Key' \
    '账号未拥有' \
    'Context Used Meter' \
    'Codex Token Usage' \
    '需要网络' \
    'Uni-Scholar' \
    'Research Kit' \
    'https://uni-scholar.asia' \
    'https://uni-scholar.asia/research-kit'; do
    rg -Fq "$contract" "$document" || fail "documentation contract missing in $(basename "$document"): $contract"
  done
  rg -q '不(提供|赠送) GPT API 额度' "$document" \
    || fail "documentation contract missing no-GPT-credit boundary in $(basename "$document")"
  ! rg -Fq '默认：DeepSeek/Kimi API' "$document" \
    || fail "documentation retains DeepSeek/Kimi-only default: $(basename "$document")"
  ! rg -Fq '模型仍由 DeepSeek/Kimi API 运行' "$document" \
    || fail "documentation retains DeepSeek/Kimi-only model claim: $(basename "$document")"
  ! rg -Fq '必须先打开原版 Codex 登录' "$document" \
    || fail "documentation wrongly requires the original Codex login: $(basename "$document")"
  ! rg -Fq 'OpenAI 授权会提供 GPT API 额度' "$document" \
    || fail "documentation overpromises GPT API credit: $(basename "$document")"
done

REPORT_SOURCE="$(/usr/bin/sed -n '/^prepare_report() {/,/^publish_report() {/p' "$ROOT/Resources/installer-core.sh")"
for report_contract in \
  'OpenAI authorization: %s' \
  'Context Used Meter: 101 · enabled · runtime-smoke-pass' \
  'Codex Token Usage: 0.1.7 · enabled · runtime-smoke-pass' \
  'authorization_status=authorized' \
  'authorization_status=skipped'; do
  [[ "$REPORT_SOURCE" == *"$report_contract"* ]] \
    || fail "minimal report source contract missing: $report_contract"
done
for forbidden_report_detail in \
  'Provider |' \
  '默认模型 |' \
  'ChatGPT/Codex |' \
  '插件市场 / 插件' \
  '备份：' \
  '检查时间：' \
  '系统：' \
  'API Key 连通性'; do
  [[ "$REPORT_SOURCE" != *"$forbidden_report_detail"* ]] \
    || fail "minimal report source retains forbidden detail: $forbidden_report_detail"
done

VERIFY_SCRIPT="$ROOT/scripts/verify-release-artifact.sh"
[[ -x "$VERIFY_SCRIPT" ]] || fail 'artifact verifier missing or not executable'
REAL_HELPER="$OUT/installer-support-real"
export REAL_HELPER
xcrun swiftc \
  "$ROOT/Sources/InstallerDomain.swift" \
  "$ROOT/Sources/TomlDocument.swift" \
  "$ROOT/Sources/ManagedPathPolicy.swift" \
  "$ROOT/Sources/InstallerBackup.swift" \
  "$ROOT/Sources/InstallExpectation.swift" \
  "$ROOT/Sources/InstallerConfiguration.swift" \
  "$ROOT/Sources/ProviderCatalog.swift" \
  "$ROOT/Sources/ScriptMarketInstaller.swift" \
  "$ROOT/Sources/InstallerSupportCLI.swift" \
  -o "$REAL_HELPER"

FIXTURE_STAGE="$OUT/dmg-stage"
FIXTURE_APP="$FIXTURE_STAGE/Codex 一键安装.app"
FIXTURE_RESOURCES="$FIXTURE_APP/Contents/Resources"
FIXTURE_PAYLOADS="$FIXTURE_RESOURCES/offline-payloads"
HELPER_LOG="$OUT/helper.log"
export HELPER_LOG
mkdir -p "$FIXTURE_APP/Contents/MacOS" \
  "$FIXTURE_PAYLOADS/apps" \
  "$FIXTURE_PAYLOADS/plugins/marketplaces" \
  "$FIXTURE_PAYLOADS/plugins/cache" \
  "$FIXTURE_PAYLOADS/script-market" \
  "$FIXTURE_PAYLOADS/sources" \
  "$FIXTURE_PAYLOADS/metadata" \
  "$FIXTURE_STAGE/第三方许可与源码"
printf '%s\n' 'int main(void) { return 0; }' > "$OUT/main.c"
xcrun clang -target arm64-apple-macos14.0 "$OUT/main.c" -o "$OUT/main-arm64"
xcrun clang -target x86_64-apple-macos14.0 "$OUT/main.c" -o "$OUT/main-x86_64"
/usr/bin/lipo -create "$OUT/main-arm64" "$OUT/main-x86_64" -output "$FIXTURE_APP/Contents/MacOS/CodexOneClickInstaller"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexOneClickInstaller</string>
<key>CFBundleIdentifier</key><string>com.codexoneclick.fixture</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
/bin/cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$FIXTURE_RESOURCES/AppIcon.icns"
printf '%s\n' '{"providers":[]}' > "$FIXTURE_PAYLOADS/model-catalog.json"
/bin/cp "$FIXTURE_PAYLOADS/model-catalog.json" "$FIXTURE_RESOURCES/model-catalog.json"
/bin/cp "$ROOT/Resources/plugin-catalog.json" "$FIXTURE_PAYLOADS/plugin-catalog.json"

marketplace_plugins() {
  case "$1" in
    openai-bundled) printf '%s\n' browser chrome computer-use latex ;;
    openai-primary-runtime) printf '%s\n' pdf documents spreadsheets presentations ;;
    openai-curated) printf '%s\n' github ;;
    *) return 1 ;;
  esac
}

for marketplace in openai-bundled openai-primary-runtime openai-curated; do
  marketplace_root="$FIXTURE_PAYLOADS/plugins/marketplaces/$marketplace"
  mkdir -p "$marketplace_root/.agents/plugins"
  printf '{"name":"%s","plugins":[]}\n' "$marketplace" \
    > "$marketplace_root/.agents/plugins/marketplace.json"
  while IFS= read -r plugin; do
    plugin_root="$FIXTURE_PAYLOADS/plugins/cache/$marketplace/$plugin/1.0.0"
    mkdir -p "$plugin_root/.codex-plugin"
    printf '{"name":"%s","version":"1.0.0"}\n' "$plugin" \
      > "$plugin_root/.codex-plugin/plugin.json"
  done < <(marketplace_plugins "$marketplace")
done

(
  cd "$FIXTURE_PAYLOADS/plugins"
  find marketplaces cache -type f -print | LC_ALL=C sort | while IFS= read -r relative; do
    digest="$(shasum -a 256 "$relative" | awk '{print tolower($1)}')"
    jq -cn --arg path "$relative" --arg sha256 "$digest" '{path:$path,sha256:$sha256}'
  done | jq -s '{schemaVersion:1,files:.}' > file-manifest.json
)

printf '%s\n' 'fixture ChatGPT arm64' > "$FIXTURE_PAYLOADS/apps/Codex-arm64.dmg"
printf '%s\n' 'fixture ChatGPT x86_64' > "$FIXTURE_PAYLOADS/apps/Codex-x64.dmg"
printf '%s\n' 'fixture Codex++ arm64' > "$FIXTURE_PAYLOADS/apps/CodexPlusPlus-arm64.dmg"
printf '%s\n' 'fixture Codex++ x86_64' > "$FIXTURE_PAYLOADS/apps/CodexPlusPlus-x86_64.dmg"
printf '%s\n' '{"scripts":[]}' > "$FIXTURE_PAYLOADS/script-market/index.json"
printf '%s\n' 'fixture Codex++ source' > "$FIXTURE_PAYLOADS/sources/CodexPlusPlus-v1.tar.gz"
chat_arm_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/apps/Codex-arm64.dmg" | awk '{print $1}')"
chat_x64_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/apps/Codex-x64.dmg" | awk '{print $1}')"
plus_arm_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/apps/CodexPlusPlus-arm64.dmg" | awk '{print $1}')"
plus_x64_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/apps/CodexPlusPlus-x86_64.dmg" | awk '{print $1}')"
model_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/model-catalog.json" | awk '{print $1}')"
plugin_manifest_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/plugins/file-manifest.json" | awk '{print $1}')"
script_index_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/script-market/index.json" | awk '{print $1}')"
source_sha="$(shasum -a 256 "$FIXTURE_PAYLOADS/sources/CodexPlusPlus-v1.tar.gz" | awk '{print $1}')"
jq -n \
  --arg chatArm "$chat_arm_sha" \
  --arg chatX64 "$chat_x64_sha" \
  --arg plusArm "$plus_arm_sha" \
  --arg plusX64 "$plus_x64_sha" \
  --arg model "$model_sha" \
  --arg plugins "$plugin_manifest_sha" \
  --arg scripts "$script_index_sha" \
  --arg source "$source_sha" \
  '{schemaVersion:1,generatedAt:"2026-07-21T00:00:00Z",files:[
  {id:"chatgpt-codex-arm64",version:"1",architecture:"arm64",relativePath:"apps/Codex-arm64.dmg",sha256:$chatArm,sourceURL:"https://example.invalid/chat-arm",format:"dmg"},
  {id:"chatgpt-codex-x86_64",version:"1",architecture:"x86_64",relativePath:"apps/Codex-x64.dmg",sha256:$chatX64,sourceURL:"https://example.invalid/chat-x64",format:"dmg"},
  {id:"codex-plus-plus-arm64",version:"1",architecture:"arm64",relativePath:"apps/CodexPlusPlus-arm64.dmg",sha256:$plusArm,sourceURL:"https://example.invalid/plus-arm",format:"dmg"},
  {id:"codex-plus-plus-x86_64",version:"1",architecture:"x86_64",relativePath:"apps/CodexPlusPlus-x86_64.dmg",sha256:$plusX64,sourceURL:"https://example.invalid/plus-x64",format:"dmg"},
  {id:"model-catalog",version:"1",architecture:"any",relativePath:"model-catalog.json",sha256:$model,sourceURL:"https://example.invalid/models",format:"file"},
  {id:"plugin-marketplaces",version:"1",architecture:"any",relativePath:"plugins",sha256:$plugins,sourceURL:"https://example.invalid/plugins",format:"directory"},
  {id:"script-market",version:"1",architecture:"any",relativePath:"script-market",sha256:$scripts,sourceURL:"https://example.invalid/scripts",format:"directory"},
  {id:"codex-plus-plus-source",version:"1",architecture:"source",relativePath:"sources/CodexPlusPlus-v1.tar.gz",sha256:$source,sourceURL:"https://example.invalid/source",format:"archive"}
]}' > "$FIXTURE_PAYLOADS/payload-manifest.json"
"$REAL_HELPER" plugin-package-validate \
  --root "$FIXTURE_PAYLOADS/plugins" \
  --catalog "$FIXTURE_PAYLOADS/plugin-catalog.json" >/dev/null \
  || fail 'baseline fixture is invalid under the production plugin validator'
cat > "$FIXTURE_RESOURCES/installer-support" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${HELPER_LOG:?}"
exec "${REAL_HELPER:?}" "$@"
SH
chmod +x "$FIXTURE_RESOURCES/installer-support"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FIXTURE_RESOURCES/installer-core.sh"
chmod +x "$FIXTURE_RESOURCES/installer-core.sh"
printf '%s\n' '请先阅读。' > "$FIXTURE_STAGE/开始安装前请看.txt"
printf '%s\n' '<html><body>安装说明</body></html>' > "$FIXTURE_STAGE/小白安装说明.html"
printf '%s\n' 'AGPL-3.0-only' > "$FIXTURE_STAGE/第三方许可与源码/AGPL-3.0.txt"
printf '%s\n' 'fixture notices' > "$FIXTURE_STAGE/第三方许可与源码/第三方许可说明.md"
ln -s /Applications "$FIXTURE_STAGE/Applications"
/usr/bin/codesign --force --sign - "$FIXTURE_APP" >/dev/null
mkdir -p "$OUT/base"
FIXTURE_DMG="$OUT/base/Codex-一键安装.dmg"
/usr/bin/hdiutil create -quiet -volname 'Codex 一键安装' -srcfolder "$FIXTURE_STAGE" -format UDZO "$FIXTURE_DMG"
verification="$(TEST_MODE=1 bash "$VERIFY_SCRIPT" "$FIXTURE_DMG")"
expected='{"status":"pass","dmg":"Codex-一键安装.dmg","architectures":["arm64","x86_64"],"notarized":false,"payloadCount":8,"hardwareAttested":false}'
[[ "$verification" == "$expected" ]] || fail "unexpected verification JSON: $verification"

fixture_failures=0

EXTRA_STAGE="$OUT/plugin-extra-stage"
/usr/bin/ditto "$FIXTURE_STAGE" "$EXTRA_STAGE"
printf '%s\n' 'not listed' > "$EXTRA_STAGE/Codex 一键安装.app/Contents/Resources/offline-payloads/plugins/cache/unlisted.txt"
/usr/bin/codesign --force --sign - "$EXTRA_STAGE/Codex 一键安装.app" >/dev/null
mkdir -p "$OUT/plugin-extra"
EXTRA_DMG="$OUT/plugin-extra/Codex-一键安装.dmg"
/usr/bin/hdiutil create -quiet -volname 'Codex 一键安装' -srcfolder "$EXTRA_STAGE" -format UDZO "$EXTRA_DMG"
set +e
extra_output="$(TEST_MODE=1 bash "$VERIFY_SCRIPT" "$EXTRA_DMG" 2>&1)"
extra_status=$?
set -e
if [[ "$extra_status" == 0 ]]; then
  printf '%s\n' 'installer-package-tests: FAIL: verifier accepted an unlisted plugin file' >&2
  fixture_failures=1
elif ! rg -Fq 'plugin package validation failed' <<< "$extra_output"; then
  printf 'installer-package-tests: FAIL: unexpected unlisted-plugin failure: %s\n' "$extra_output" >&2
  fixture_failures=1
fi

MODEL_STAGE="$OUT/model-divergence-stage"
/usr/bin/ditto "$FIXTURE_STAGE" "$MODEL_STAGE"
printf '%s\n' '{"providers":[{"id":"diverged"}]}' \
  > "$MODEL_STAGE/Codex 一键安装.app/Contents/Resources/model-catalog.json"
/usr/bin/codesign --force --sign - "$MODEL_STAGE/Codex 一键安装.app" >/dev/null
mkdir -p "$OUT/model-divergence"
MODEL_DMG="$OUT/model-divergence/Codex-一键安装.dmg"
/usr/bin/hdiutil create -quiet -volname 'Codex 一键安装' -srcfolder "$MODEL_STAGE" -format UDZO "$MODEL_DMG"
set +e
model_output="$(TEST_MODE=1 bash "$VERIFY_SCRIPT" "$MODEL_DMG" 2>&1)"
model_status=$?
set -e
if [[ "$model_status" == 0 ]]; then
  printf '%s\n' 'installer-package-tests: FAIL: verifier accepted divergent bundled model catalogs' >&2
  fixture_failures=1
elif ! rg -Fq 'bundled model catalog differs from offline payload' <<< "$model_output"; then
  printf 'installer-package-tests: FAIL: unexpected model-catalog failure: %s\n' "$model_output" >&2
  fixture_failures=1
fi

FILESYSTEM_STAGE="$OUT/filesystem-extra-stage"
/usr/bin/ditto "$FIXTURE_STAGE" "$FILESYSTEM_STAGE"
printf '%s\n' 'not listed in the exact payload filesystem' \
  > "$FILESYSTEM_STAGE/Codex 一键安装.app/Contents/Resources/offline-payloads/metadata/unlisted.txt"
/usr/bin/codesign --force --sign - "$FILESYSTEM_STAGE/Codex 一键安装.app" >/dev/null
mkdir -p "$OUT/filesystem-extra"
FILESYSTEM_DMG="$OUT/filesystem-extra/Codex-一键安装.dmg"
/usr/bin/hdiutil create -quiet -volname 'Codex 一键安装' -srcfolder "$FILESYSTEM_STAGE" -format UDZO "$FILESYSTEM_DMG"
set +e
filesystem_output="$(TEST_MODE=1 bash "$VERIFY_SCRIPT" "$FILESYSTEM_DMG" 2>&1)"
filesystem_status=$?
set -e
if [[ "$filesystem_status" == 0 ]]; then
  printf '%s\n' 'installer-package-tests: FAIL: verifier accepted an unlisted payload metadata file' >&2
  fixture_failures=1
elif ! rg -Fq 'offline payload filesystem contains unexpected entry: metadata/unlisted.txt' <<< "$filesystem_output"; then
  printf 'installer-package-tests: FAIL: unexpected payload-filesystem failure: %s\n' "$filesystem_output" >&2
  fixture_failures=1
fi

if ! rg -Fq 'plugin-package-validate --root ' "$HELPER_LOG"; then
  printf '%s\n' 'installer-package-tests: FAIL: verifier did not invoke packaged plugin validator' >&2
  fixture_failures=1
fi
[[ "$fixture_failures" == 0 && "$build_boundary_failure" == 0 ]] || exit 1

BUILT_APP="$ROOT/build/Codex 一键安装.app"
if [[ -d "$BUILT_APP" ]]; then
  executable="$BUILT_APP/Contents/MacOS/CodexOneClickInstaller"
  architectures="$(lipo -archs "$executable")"
  [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || fail 'built installer is not universal'
  [[ -x "$BUILT_APP/Contents/Resources/installer-core.sh" ]] || fail 'built core missing'
  [[ -x "$BUILT_APP/Contents/Resources/installer-support" ]] || fail 'built helper missing'
  [[ -s "$BUILT_APP/Contents/Resources/AppIcon.icns" ]] || fail 'built app icon missing'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUILT_APP/Contents/Info.plist")" == AppIcon ]] \
    || fail 'built app icon declaration invalid'
else
  printf '%s\n' 'installer-package-tests: artifact not built: source contracts passed'
fi

BUILT_DMG="$ROOT/dist/Codex-一键安装.dmg"
if [[ -f "$BUILT_DMG" ]]; then
  [[ -f "$ROOT/dist/SHA256SUMS.txt" ]] || fail 'built DMG checksum manifest missing'
  (
    cd "$ROOT/dist"
    shasum -a 256 -c SHA256SUMS.txt >/dev/null
  ) || fail 'built DMG checksum manifest does not match artifact'
fi

printf '%s\n' 'installer-package-tests: PASS'
