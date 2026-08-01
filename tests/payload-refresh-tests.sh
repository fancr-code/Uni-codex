#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT%/}"
OUT="$(mktemp -d "$TEST_TMP_ROOT/codex-payload-refresh-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

translation_url='https://raw.githubusercontent.com/hL091015/CodexPlusPlusScriptMarket/main/scripts/zh_CN%E6%B1%89%E5%8C%96.user.js'
translation_commit='482076e76af9c78f18e3998bd99a96dc6033eb5d'
translation_upstream_sha='72214d31d425d1ce936b457aa43fcc40df55f4de3b9b140f9510c7f392cdc845'
translation_pinned_sha='be19a7930116dfe8fa1c68571d6a3bb3130714f77c7e32a6c1da543a182270f5'
jq -e \
  --arg upstream_url "$translation_url" \
  --arg commit "$translation_commit" \
  --arg upstream_sha "$translation_upstream_sha" \
  --arg pinned_sha "$translation_pinned_sha" '
    .overrides[]
    | select(.id == "codex-zhcn-translate")
    | .upstreamURL == $upstream_url and
      .upstreamSHA256 == $upstream_sha and
      .pinnedURL == ($upstream_url | sub("/main/"; "/" + $commit + "/")) and
      .pinnedSHA256 == $pinned_sha and
      .sourceCommit == $commit
  ' "$ROOT/Resources/script-market-overrides.json" >/dev/null \
  || { printf '%s\n' 'payload-refresh-tests: FAIL: translation script freeze is not canonical and immutable' >&2; exit 1; }

fail() {
  printf 'payload-refresh-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

RESOURCE_DIR="$OUT/resources"
HTTP_DIR="$OUT/http"
CAPTURE_DIR="$OUT/capture"
BUILDER_HOME="$OUT/builder-home"
OUTPUT_ROOT="$OUT/offline-payloads"
mkdir -p "$RESOURCE_DIR" "$HTTP_DIR" "$CAPTURE_DIR" "$BUILDER_HOME" "$OUTPUT_ROOT"
cp "$ROOT/Resources/upstream-sources.json" "$RESOURCE_DIR/upstream-sources.json"
cp "$ROOT/Resources/model-catalog.json" "$RESOURCE_DIR/model-catalog.json"
cp "$ROOT/Resources/plugin-catalog.json" "$RESOURCE_DIR/plugin-catalog.json"
printf '%s\n' '{"schemaVersion":2,"overrides":[]}' > "$RESOURCE_DIR/script-market-overrides.json"

printf '%s\n' 'chatgpt-arm64-dmg' > "$HTTP_DIR/Codex-arm64.dmg"
printf '%s\n' 'chatgpt-x64-dmg' > "$HTTP_DIR/Codex-x64.dmg"
printf '%s\n' 'codex-plus-arm64-dmg' > "$HTTP_DIR/CodexPlusPlus-9.8.7-macos-arm64.dmg"
printf '%s\n' 'codex-plus-x64-dmg' > "$HTTP_DIR/CodexPlusPlus-9.8.7-macos-x64.dmg"
printf '%s\n' 'windows-decoy' > "$HTTP_DIR/CodexPlusPlus-9.8.7-windows-x64.exe"
printf '%s\n' 'zip-decoy' > "$HTTP_DIR/CodexPlusPlus-9.8.7-macos-arm64.zip"
printf '%s\n' 'source-for-v9.8.7' > "$HTTP_DIR/CodexPlusPlus-v9.8.7.tar.gz"

cat > "$HTTP_DIR/release.json" <<'JSON'
{
  "tag_name": "v9.8.7",
  "assets": [
    {"name":"CodexPlusPlus-9.8.7-windows-x64.exe","browser_download_url":"https://downloads.invalid/CodexPlusPlus-9.8.7-windows-x64.exe"},
    {"name":"CodexPlusPlus-9.8.7-macos-arm64.zip","browser_download_url":"https://downloads.invalid/CodexPlusPlus-9.8.7-macos-arm64.zip"},
    {"name":"CodexPlusPlus-9.8.7-macos-arm64.dmg","browser_download_url":"https://downloads.invalid/CodexPlusPlus-9.8.7-macos-arm64.dmg"},
    {"name":"CodexPlusPlus-9.8.7-macos-x64.dmg","browser_download_url":"https://downloads.invalid/CodexPlusPlus-9.8.7-macos-x64.dmg"},
    {"name":"CodexPlusPlus-9.8.70-macos-arm64.dmg","browser_download_url":"https://downloads.invalid/CodexPlusPlus-9.8.70-macos-arm64.dmg"}
  ]
}
JSON

printf '%s\n' 'window.zh = true;' > "$HTTP_DIR/codex-zhcn-translate.js"
printf '%s\n' 'window.meter = true;' > "$HTTP_DIR/codex-context-used-meter.js"
printf '%s\n' 'window.third = true;' > "$HTTP_DIR/third-script.js"
zh_sha="$(shasum -a 256 "$HTTP_DIR/codex-zhcn-translate.js" | awk '{print $1}')"
zh_blob_sha="$(git hash-object "$HTTP_DIR/codex-zhcn-translate.js")"
declared_zh_sha="$zh_sha"
meter_sha="$(shasum -a 256 "$HTTP_DIR/codex-context-used-meter.js" | awk '{print toupper($1)}')"
meter_sha_lower="$(printf '%s' "$meter_sha" | tr '[:upper:]' '[:lower:]')"
third_sha="$(shasum -a 256 "$HTTP_DIR/third-script.js" | awk '{print $1}')"
jq -n '{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$HTTP_DIR/zh-commit.json"
jq -n \
  --arg sha "$zh_blob_sha" \
  '{sha:$sha,download_url:"https://raw.githubusercontent.com/example/market/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/scripts/zh.js"}' \
  > "$HTTP_DIR/zh-contents.json"
jq -n \
  --arg zh "$declared_zh_sha" \
  --arg meter "$meter_sha" \
  --arg third "$third_sha" \
  '{version:1,updated_at:"2026-07-21T00:00:00Z",scripts:[
    {id:"codex-zhcn-translate",name:"中文",version:"1.0.0",script_url:"https://raw.githubusercontent.com/example/market/main/scripts/zh.js",homepage:"https://example.invalid/zh",sha256:$zh},
    {id:"codex-context-used-meter",name:"Meter",version:"2.0.0",script_url:"https://scripts.invalid/codex-context-used-meter.js",homepage:"https://example.invalid/meter",sha256:$meter},
    {id:"third-script",name:"Third",version:"3.0.0",script_url:"https://scripts.invalid/third-script.js",homepage:"",sha256:$third}
  ]}' > "$HTTP_DIR/script-index.json"

FAKE_CURL="$OUT/fake-curl"
cat > "$FAKE_CURL" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${DEEPSEEK_CATALOG_KEY:-}" && -z "${KIMI_OPEN_CATALOG_KEY:-}" ]] || {
  printf '%s\n' 'catalog key leaked to curl environment' >&2
  exit 90
}
output=''
url=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]]
printf '%s\n' "$url" >> "$CAPTURE_DIR/curl.log"
case "$url" in
  https://persistent.oaistatic.com/codex-app-prod/Codex.dmg) source="$FIXTURE_HTTP/Codex-arm64.dmg" ;;
  https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg) source="$FIXTURE_HTTP/Codex-x64.dmg" ;;
  https://api.github.com/repos/BigPizzaV3/CodexPlusPlus/releases/latest) source="$FIXTURE_HTTP/release.json" ;;
  https://api.github.com/repos/BigPizzaV3/CodexPlusPlus/releases/tags/v9.8.7) source="$FIXTURE_HTTP/release.json" ;;
  https://downloads.invalid/CodexPlusPlus-9.8.7-macos-arm64.dmg) source="$FIXTURE_HTTP/CodexPlusPlus-9.8.7-macos-arm64.dmg" ;;
  https://downloads.invalid/CodexPlusPlus-9.8.7-macos-x64.dmg) source="$FIXTURE_HTTP/CodexPlusPlus-9.8.7-macos-x64.dmg" ;;
  https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/tags/v9.8.7.tar.gz) source="$FIXTURE_HTTP/CodexPlusPlus-v9.8.7.tar.gz" ;;
  https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlusScriptMarket/main/index.json) source="$FIXTURE_HTTP/script-index.json" ;;
  https://raw.githubusercontent.com/example/market/main/scripts/zh.js) source="$FIXTURE_HTTP/codex-zhcn-translate.js" ;;
  https://api.github.com/repos/example/market/commits/main) source="$FIXTURE_HTTP/zh-commit.json" ;;
  "https://api.github.com/repos/example/market/contents/scripts/zh.js?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") source="$FIXTURE_HTTP/zh-contents.json" ;;
  https://raw.githubusercontent.com/example/market/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/scripts/zh.js) source="$FIXTURE_HTTP/codex-zhcn-translate.js" ;;
  https://scripts.invalid/codex-context-used-meter.js) source="$FIXTURE_HTTP/codex-context-used-meter.js" ;;
  https://scripts.invalid/third-script.js) source="$FIXTURE_HTTP/third-script.js" ;;
  *) printf 'unexpected URL: %s\n' "$url" >&2; exit 91 ;;
esac
cp "$source" "$output"
SH
chmod +x "$FAKE_CURL"

FAKE_INSPECT="$OUT/fake-app-inspect"
cat > "$FAKE_INSPECT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$(basename "$1")" in
  Codex-arm64.dmg)
    printf '%s\n' '{"version":"26.999.1","architectures":["arm64"],"bundleIdentifiers":["com.openai.codex"],"teamIdentifier":"2DC432GLL2","applications":[{"bundleIdentifier":"com.openai.codex","version":"26.999.1","architectures":["arm64"],"teamIdentifier":"2DC432GLL2"}]}'
    ;;
  Codex-x64.dmg)
    if [[ "${APP_INSPECT_THIN:-0}" == 1 ]]; then
      printf '%s\n' '{"version":"26.999.1","architectures":["arm64"],"bundleIdentifiers":["com.openai.codex"],"teamIdentifier":"2DC432GLL2","applications":[{"bundleIdentifier":"com.openai.codex","version":"26.999.1","architectures":["arm64"],"teamIdentifier":"2DC432GLL2"}]}'
    else
      printf '%s\n' '{"version":"26.999.1","architectures":["x86_64"],"bundleIdentifiers":["com.openai.codex"],"teamIdentifier":"2DC432GLL2","applications":[{"bundleIdentifier":"com.openai.codex","version":"26.999.1","architectures":["x86_64"],"teamIdentifier":"2DC432GLL2"}]}'
    fi
    ;;
  *arm64.dmg)
    if [[ "${APP_INSPECT_SPLIT:-0}" == 1 ]]; then
      printf '%s\n' '{"version":"9.8.7","architectures":["arm64","x86_64"],"bundleIdentifiers":["com.bigpizzav3.codexplusplus","com.bigpizzav3.codexplusplus.manager"],"teamIdentifier":"","applications":[{"bundleIdentifier":"com.bigpizzav3.codexplusplus","version":"9.8.7","architectures":["x86_64"]},{"bundleIdentifier":"com.bigpizzav3.codexplusplus.manager","version":"9.8.7","architectures":["arm64"]}]}'
    else
      printf '%s\n' '{"version":"9.8.7","architectures":["arm64"],"bundleIdentifiers":["com.bigpizzav3.codexplusplus","com.bigpizzav3.codexplusplus.manager"],"teamIdentifier":"","applications":[{"bundleIdentifier":"com.bigpizzav3.codexplusplus","version":"9.8.7","architectures":["arm64"]},{"bundleIdentifier":"com.bigpizzav3.codexplusplus.manager","version":"9.8.7","architectures":["arm64"]}]}'
    fi
    ;;
  *x64.dmg)
    printf '%s\n' '{"version":"9.8.7","architectures":["x86_64"],"bundleIdentifiers":["com.bigpizzav3.codexplusplus","com.bigpizzav3.codexplusplus.manager"],"teamIdentifier":"","applications":[{"bundleIdentifier":"com.bigpizzav3.codexplusplus","version":"9.8.7","architectures":["x86_64"]},{"bundleIdentifier":"com.bigpizzav3.codexplusplus.manager","version":"9.8.7","architectures":["x86_64"]}]}'
    ;;
  *) exit 92 ;;
esac
SH
chmod +x "$FAKE_INSPECT"

FAKE_PAYLOAD_FIND="$OUT/fake-payload-find"
cat > "$FAKE_PAYLOAD_FIND" <<'SH'
#!/usr/bin/env bash
exit 96
SH
chmod +x "$FAKE_PAYLOAD_FIND"

FAKE_SUPPORT="$OUT/fake-support"
cat > "$FAKE_SUPPORT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${DEEPSEEK_CATALOG_KEY:-}" && -z "${KIMI_OPEN_CATALOG_KEY:-}" ]] || {
  printf '%s\n' 'catalog key leaked to support environment' >&2
  exit 93
}
case "${1:-}" in
  plugin-package-validate)
    printf '%s\n' "$5" >> "$CAPTURE_DIR/plugin-catalog-paths.txt"
    if [[ -n "${PLUGIN_CATALOG_SOURCE_TO_MUTATE:-}" ]]; then
      printf '%s\n' '{"schemaVersion":1,"plugins":[]}' > "$PLUGIN_CATALOG_SOURCE_TO_MUTATE"
    fi
    printf '%s\n' '{"status":"valid"}'
    ;;
  manifest-validate)
    printf '%s\n' '{"status":"valid"}'
    ;;
  refresh-models)
    provider="$3"
    catalog="$5"
    key_file="$(mktemp "$CAPTURE_DIR/model-key.XXXXXX")"
    cat > "$key_file"
    shasum -a 256 "$key_file" | awk -v provider="$provider" '{print provider " " $1}' >> "$CAPTURE_DIR/model-key-shas.txt"
    rm -f "$key_file"
    printf '%s\n' "$provider" >> "$CAPTURE_DIR/model-providers.txt"
    printf '%s\t%s\n' "$provider" "$catalog" >> "$CAPTURE_DIR/model-catalog-paths.txt"
    refreshed="$(mktemp "$catalog.refresh.XXXXXX")"
    jq --arg provider "$provider" '.generatedAt += "-" + $provider' "$catalog" > "$refreshed"
    mv -f "$refreshed" "$catalog"
    printf '{"count":1,"provider":"%s"}\n' "$provider"
    ;;
  model-catalog-validate)
    [[ "${MODEL_CATALOG_VALIDATE_FAIL:-0}" != 1 ]] || exit 95
    printf '%s\n' '{"status":"valid"}'
    ;;
  *) printf 'unexpected support command: %s\n' "${1:-}" >&2; exit 94 ;;
esac
SH
chmod +x "$FAKE_SUPPORT"

make_plugin_fixture() {
  local marketplace="$1"
  local plugin="$2"
  local version="$3"
  local marketplace_root="$4"
  local cache_root="$BUILDER_HOME/.codex/plugins/cache/$marketplace/$plugin/$version"
  mkdir -p "$marketplace_root/plugins/$plugin/.codex-plugin" "$cache_root/.codex-plugin"
  printf '{"name":"%s","version":"%s"}\n' "$plugin" "$version" > "$marketplace_root/plugins/$plugin/.codex-plugin/plugin.json"
  printf '# %s marketplace\n' "$plugin" > "$marketplace_root/plugins/$plugin/README.md"
  cp "$marketplace_root/plugins/$plugin/.codex-plugin/plugin.json" "$cache_root/.codex-plugin/plugin.json"
  printf '# %s cache\n' "$plugin" > "$cache_root/README.md"
}

BUNDLED_MARKET="$BUILDER_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
PRIMARY_MARKET="$BUILDER_HOME/.cache/codex-runtimes/codex-primary-runtime/plugins/openai-primary-runtime"
CURATED_MARKET="$BUILDER_HOME/.codex/.tmp/plugins"
for pair in \
  'openai-bundled|browser|1.0.1' \
  'openai-bundled|chrome|1.0.2' \
  'openai-bundled|computer-use|1.0.3' \
  'openai-bundled|latex|1.0.4' \
  'openai-primary-runtime|pdf|2.0.1' \
  'openai-primary-runtime|documents|2.0.2' \
  'openai-primary-runtime|spreadsheets|2.0.3' \
  'openai-primary-runtime|presentations|2.0.4' \
  'openai-curated|github|3.0.1'; do
  IFS='|' read -r marketplace plugin version <<< "$pair"
  case "$marketplace" in
    openai-bundled) market_root="$BUNDLED_MARKET" ;;
    openai-primary-runtime) market_root="$PRIMARY_MARKET" ;;
    openai-curated) market_root="$CURATED_MARKET" ;;
  esac
  make_plugin_fixture "$marketplace" "$plugin" "$version" "$market_root"
done
for spec in \
  "$BUNDLED_MARKET|openai-bundled" \
  "$PRIMARY_MARKET|openai-primary-runtime" \
  "$CURATED_MARKET|openai-curated"; do
  IFS='|' read -r market_root marketplace <<< "$spec"
  mkdir -p "$market_root/.agents/plugins"
  printf '{"name":"%s","plugins":[]}\n' "$marketplace" > "$market_root/.agents/plugins/marketplace.json"
done

deep_key='sk-deep-refresh-secret-123'
kimi_key='sk-kimi-refresh-secret-456'
export FIXTURE_HTTP="$HTTP_DIR" CAPTURE_DIR

run_refresh() {
  local output_root="$1"
  local log_file="$2"
  local resource_dir="${3:-$RESOURCE_DIR}"
  if [[ "$#" -gt 3 ]]; then
    DEEPSEEK_CATALOG_KEY="$deep_key" \
    KIMI_OPEN_CATALOG_KEY="$kimi_key" \
    TEST_MODE=1 \
    CURL_BIN="$FAKE_CURL" \
    APP_INSPECT_BIN="$FAKE_INSPECT" \
    SUPPORT_TOOL="$FAKE_SUPPORT" \
    BUILDER_HOME="$BUILDER_HOME" \
    OUTPUT_ROOT="$output_root" \
    RESOURCE_DIR_OVERRIDE="$resource_dir" \
    GENERATED_AT_OVERRIDE='2026-07-21T12:00:00Z' \
    bash "$ROOT/scripts/refresh-offline-payloads.sh" "${@:4}" > "$log_file" 2>&1
  else
    DEEPSEEK_CATALOG_KEY="$deep_key" \
    KIMI_OPEN_CATALOG_KEY="$kimi_key" \
    TEST_MODE=1 \
    CURL_BIN="$FAKE_CURL" \
    APP_INSPECT_BIN="$FAKE_INSPECT" \
    SUPPORT_TOOL="$FAKE_SUPPORT" \
    BUILDER_HOME="$BUILDER_HOME" \
    OUTPUT_ROOT="$output_root" \
    RESOURCE_DIR_OVERRIDE="$resource_dir" \
    GENERATED_AT_OVERRIDE='2026-07-21T12:00:00Z' \
    bash "$ROOT/scripts/refresh-offline-payloads.sh" > "$log_file" 2>&1
  fi
}

make_resource_fixture() {
  local destination="$1"
  mkdir -p "$destination"
  cp "$RESOURCE_DIR/upstream-sources.json" "$destination/upstream-sources.json"
  cp "$RESOURCE_DIR/model-catalog.json" "$destination/model-catalog.json"
  cp "$RESOURCE_DIR/plugin-catalog.json" "$destination/plugin-catalog.json"
  cp "$RESOURCE_DIR/script-market-overrides.json" "$destination/script-market-overrides.json"
  if [[ -d "$RESOURCE_DIR/script-market-sources" ]]; then
    cp -R "$RESOURCE_DIR/script-market-sources" "$destination/script-market-sources"
  fi
}

refresh_log="$OUT/refresh.log"
if ! run_refresh "$OUTPUT_ROOT" "$refresh_log"; then
  cat "$refresh_log" >&2
  fail 'baseline payload refresh failed'
fi

[[ -f "$OUTPUT_ROOT/apps/Codex-arm64.dmg" ]] || fail 'official arm64 Codex DMG missing'
[[ -f "$OUTPUT_ROOT/apps/Codex-x64.dmg" ]] || fail 'official x64 Codex DMG missing'
[[ -f "$OUTPUT_ROOT/apps/CodexPlusPlus-9.8.7-macos-arm64.dmg" ]] || fail 'arm64 Codex++ DMG missing'
[[ -f "$OUTPUT_ROOT/apps/CodexPlusPlus-9.8.7-macos-x64.dmg" ]] || fail 'x64 Codex++ DMG missing'
[[ -f "$OUTPUT_ROOT/sources/CodexPlusPlus-v9.8.7.tar.gz" ]] || fail 'matching source archive missing'
[[ ! -e "$OUTPUT_ROOT/apps/CodexPlusPlus-9.8.7-windows-x64.exe" ]] || fail 'Windows asset selected'
[[ ! -e "$OUTPUT_ROOT/apps/CodexPlusPlus-9.8.7-macos-arm64.zip" ]] || fail 'zip asset selected'
[[ "$(jq -r '.scripts | length' "$OUTPUT_ROOT/script-market/index.json")" == 3 ]] || fail 'complete script index not copied'
for id in codex-zhcn-translate codex-context-used-meter third-script; do
  [[ -f "$OUTPUT_ROOT/script-market/scripts/$id.js" ]] || fail "script $id missing"
done
[[ "$(jq -r '.scripts[] | select(.id=="codex-zhcn-translate") | .sha256' "$OUTPUT_ROOT/script-market/index.json")" == "$zh_sha" ]] \
  || fail 'baseline script hash was not preserved'

manifest="$OUTPUT_ROOT/payload-manifest.json"
jq -e '.schemaVersion == 1 and (.files | length == 8) and all(.files[]; (.sha256 | test("^[0-9a-f]{64}$")))' "$manifest" >/dev/null || fail 'payload hashes invalid'
/usr/bin/cmp -s "$OUTPUT_ROOT/model-catalog.json" "$RESOURCE_DIR/model-catalog.json" \
  || fail 'published model catalogs differ'
expected_root_entries=$'apps\nmetadata\nmodel-catalog.json\npayload-manifest.json\nplugin-catalog.json\nplugins\nscript-market\nsources'
actual_root_entries="$(find "$OUTPUT_ROOT" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_root_entries" == "$expected_root_entries" ]] || fail 'payload root is not the exact canonical filesystem set'
[[ -z "$(find "$OUTPUT_ROOT/metadata" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail 'payload metadata directory is not empty'
[[ "$(jq -r '.files[] | select(.id=="chatgpt-codex-arm64") | .architecture' "$manifest")" == arm64 ]] || fail 'Codex arm64 architecture not recorded'
[[ "$(jq -r '.files[] | select(.id=="chatgpt-codex-x86_64") | .architecture' "$manifest")" == x86_64 ]] || fail 'Codex x86_64 architecture not recorded'
[[ "$(jq -r '.files[] | select(.id=="codex-plus-plus-source") | .version' "$manifest")" == 9.8.7 ]] || fail 'source version not locked to release'
[[ "$(jq -r '.files[] | select(.id=="codex-plus-plus-source") | .sourceURL' "$manifest")" == *'/v9.8.7.tar.gz' ]] || fail 'source URL not locked to tag'
while IFS=$'\t' read -r id relative expected format; do
  case "$id" in
    plugin-marketplaces) hash_target="$OUTPUT_ROOT/plugins/file-manifest.json" ;;
    script-market) hash_target="$OUTPUT_ROOT/script-market/index.json" ;;
    *) hash_target="$OUTPUT_ROOT/$relative" ;;
  esac
  [[ -f "$hash_target" ]] || fail "hash target missing for $id"
  actual="$(shasum -a 256 "$hash_target" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || fail "payload hash mismatch for $id ($format)"
done < <(jq -r '.files[] | [.id,.relativePath,.sha256,.format] | @tsv' "$manifest")

rg -q 'CodexPlusPlus-9\.8\.7-macos-arm64\.dmg' "$CAPTURE_DIR/curl.log" || fail 'arm64 URL not downloaded'
rg -q 'CodexPlusPlus-9\.8\.7-macos-x64\.dmg' "$CAPTURE_DIR/curl.log" || fail 'x64 URL not downloaded'
! rg -q 'windows|\.zip' "$CAPTURE_DIR/curl.log" || fail 'decoy asset downloaded'

/bin/cp "$CAPTURE_DIR/model-catalog-paths.txt" "$CAPTURE_DIR/model-catalog-paths.baseline.txt"
managed_source_relative='script-market-sources/codex-context-used-meter.js'
managed_source="$RESOURCE_DIR/$managed_source_relative"
mkdir -p "$(dirname "$managed_source")"
printf '%s\n' 'window.managedMeter = true;' > "$managed_source"
managed_sha="$(shasum -a 256 "$managed_source" | awk '{print $1}')"
jq -n \
  --arg id 'codex-context-used-meter' \
  --arg upstream_url 'https://scripts.invalid/codex-context-used-meter.js' \
  --arg upstream_sha "$meter_sha_lower" \
  --arg source "$managed_source_relative" \
  --arg sha "$managed_sha" \
  --arg provenance 'test-managed-meter-v1' \
  '{schemaVersion:2,overrides:[{mode:"managed",id:$id,upstreamURL:$upstream_url,upstreamSHA256:$upstream_sha,managedSource:$source,managedSHA256:$sha,provenance:$provenance}]}' \
  > "$RESOURCE_DIR/script-market-overrides.json"
managed_output="$OUT/managed-output"
managed_log="$OUT/managed.log"
run_refresh "$managed_output" "$managed_log"
cmp "$managed_source" "$managed_output/script-market/scripts/codex-context-used-meter.js" \
  || fail 'managed script source was not copied exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-context-used-meter") | .sha256' "$managed_output/script-market/index.json")" == "$managed_sha" ]] \
  || fail 'managed script hash was not recorded exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-context-used-meter") | .managed_source' "$managed_output/script-market/index.json")" == "$managed_source_relative" ]] \
  || fail 'managed script provenance path was not recorded exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-context-used-meter") | .provenance' "$managed_output/script-market/index.json")" == test-managed-meter-v1 ]] \
  || fail 'managed script provenance was not recorded exactly'

for malformed_managed_source in '42' '"../script-market-sources/codex-context-used-meter.js"'; do
  jq --argjson managed_source "$malformed_managed_source" \
    '(.overrides[] | select(.mode == "managed") | .managedSource) = $managed_source' \
    "$RESOURCE_DIR/script-market-overrides.json" > "$RESOURCE_DIR/script-market-overrides.malformed.json"
  mv "$RESOURCE_DIR/script-market-overrides.malformed.json" "$RESOURCE_DIR/script-market-overrides.json"
  malformed_output="$OUT/malformed-managed-source-$(printf '%s' "$malformed_managed_source" | tr -cd '[:alnum:]')"
  malformed_log="$malformed_output.log"
  set +e
  run_refresh "$malformed_output" "$malformed_log"
  malformed_status=$?
  set -e
  [[ "$malformed_status" -eq 64 ]] || fail "malformed managedSource was not rejected by schema (got $malformed_status)"
done

# Restore the valid managed override for the remaining fixture cases.
jq -n \
  --arg id 'codex-context-used-meter' \
  --arg upstream_url 'https://scripts.invalid/codex-context-used-meter.js' \
  --arg upstream_sha "$meter_sha_lower" \
  --arg source "$managed_source_relative" \
  --arg sha "$managed_sha" \
  --arg provenance 'test-managed-meter-v1' \
  '{schemaVersion:2,overrides:[{mode:"managed",id:$id,upstreamURL:$upstream_url,upstreamSHA256:$upstream_sha,managedSource:$source,managedSHA256:$sha,provenance:$provenance}]}' \
  > "$RESOURCE_DIR/script-market-overrides.json"

: > "$CAPTURE_DIR/curl.log"
pinned_output="$OUT/pinned-output"
pinned_log="$OUT/pinned.log"
if ! run_refresh \
    "$pinned_output" \
    "$pinned_log" \
    "$RESOURCE_DIR" \
    --codex-plus-tag v9.8.7 \
    --prepare-codex-plus-compatibility-build; then
  cat "$pinned_log" >&2
  fail 'pinned Codex++ payload refresh failed'
fi
rg -Fq 'https://api.github.com/repos/BigPizzaV3/CodexPlusPlus/releases/tags/v9.8.7' \
  "$CAPTURE_DIR/curl.log" || fail 'pinned release metadata endpoint was not used'
! rg -Fq 'https://api.github.com/repos/BigPizzaV3/CodexPlusPlus/releases/latest' \
  "$CAPTURE_DIR/curl.log" || fail 'pinned refresh consulted the mutable latest release endpoint'
/bin/mv "$CAPTURE_DIR/model-catalog-paths.baseline.txt" "$CAPTURE_DIR/model-catalog-paths.txt"

boundary_failures=0
if rg -Fq $'\t'"$OUTPUT_ROOT/model-catalog.json" "$CAPTURE_DIR/model-catalog-paths.txt"; then
  printf '%s\n' 'payload-refresh-tests: FAIL: provider refresh operated on the published model catalog' >&2
  boundary_failures=1
fi
while IFS=$'\t' read -r provider catalog_path; do
  case "$catalog_path" in
    "$OUTPUT_ROOT"/.model-catalog.json.refresh.*) ;;
    *)
      printf 'payload-refresh-tests: FAIL: %s provider did not use a unique sibling catalog stage: %s\n' "$provider" "$catalog_path" >&2
      boundary_failures=1
      ;;
  esac
done < "$CAPTURE_DIR/model-catalog-paths.txt"

for leaf in model-catalog.json plugin-catalog.json payload-manifest.json; do
  leaf_case="${leaf//[^A-Za-z0-9]/-}"
  leaf_output="$OUT/leaf-$leaf_case-output"
  leaf_resources="$OUT/leaf-$leaf_case-resources"
  leaf_external="$OUT/leaf-$leaf_case-external"
  leaf_log="$OUT/leaf-$leaf_case.log"
  mkdir -p "$leaf_output"
  make_resource_fixture "$leaf_resources"
  printf '%s\n' "outside $leaf must remain unchanged" > "$leaf_external"
  ln -s "$leaf_external" "$leaf_output/$leaf"
  set +e
  run_refresh "$leaf_output" "$leaf_log" "$leaf_resources"
  leaf_status=$?
  set -e
  if [[ "$leaf_status" -ne 65 ]]; then
    printf 'payload-refresh-tests: FAIL: pre-existing %s symlink did not exit 65 (got %s)\n' "$leaf" "$leaf_status" >&2
    cat "$leaf_log" >&2
    boundary_failures=1
  fi
  if [[ "$(cat "$leaf_external")" != "outside $leaf must remain unchanged" ]]; then
    printf 'payload-refresh-tests: FAIL: pre-existing %s symlink changed an external file\n' "$leaf" >&2
    boundary_failures=1
  fi
  if [[ -e "$leaf_output/apps/Codex-arm64.dmg" ]]; then
    printf 'payload-refresh-tests: FAIL: pre-existing %s symlink was not rejected before payload mutation\n' "$leaf" >&2
    boundary_failures=1
  fi
done

resource_leaf_output="$OUT/resource-model-leaf-output"
resource_leaf_resources="$OUT/resource-model-leaf-resources"
resource_leaf_external="$OUT/resource-model-leaf-external.json"
resource_leaf_log="$OUT/resource-model-leaf.log"
make_resource_fixture "$resource_leaf_resources"
cp "$resource_leaf_resources/model-catalog.json" "$resource_leaf_external"
resource_leaf_sha="$(shasum -a 256 "$resource_leaf_external" | awk '{print $1}')"
rm -f "$resource_leaf_resources/model-catalog.json"
ln -s "$resource_leaf_external" "$resource_leaf_resources/model-catalog.json"
set +e
run_refresh "$resource_leaf_output" "$resource_leaf_log" "$resource_leaf_resources"
resource_leaf_status=$?
set -e
if [[ "$resource_leaf_status" -ne 65 ]]; then
  printf 'payload-refresh-tests: FAIL: pre-existing resource model-catalog symlink did not exit 65 (got %s)\n' "$resource_leaf_status" >&2
  cat "$resource_leaf_log" >&2
  boundary_failures=1
fi
if [[ "$(shasum -a 256 "$resource_leaf_external" | awk '{print $1}')" != "$resource_leaf_sha" ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: resource model-catalog symlink changed an external file' >&2
  boundary_failures=1
fi
if [[ -e "$resource_leaf_output/apps/Codex-arm64.dmg" ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: resource model-catalog symlink was not rejected before payload mutation' >&2
  boundary_failures=1
fi

unsafe_root_output="$OUT/unsafe-root-extra-output"
unsafe_root_resources="$OUT/unsafe-root-extra-resources"
unsafe_root_external="$OUT/unsafe-root-extra-external"
unsafe_root_log="$OUT/unsafe-root-extra.log"
mkdir -p "$unsafe_root_output"
make_resource_fixture "$unsafe_root_resources"
printf '%s\n' 'outside root extra must remain unchanged' > "$unsafe_root_external"
ln -s "$unsafe_root_external" "$unsafe_root_output/unlisted-root-link"
set +e
run_refresh "$unsafe_root_output" "$unsafe_root_log" "$unsafe_root_resources"
unsafe_root_status=$?
set -e
if [[ "$unsafe_root_status" -ne 65 || -e "$unsafe_root_output/apps/Codex-arm64.dmg" ]]; then
  printf 'payload-refresh-tests: FAIL: unsafe payload-root extra was not rejected before mutation (got %s)\n' "$unsafe_root_status" >&2
  cat "$unsafe_root_log" >&2
  boundary_failures=1
fi
if [[ "$(cat "$unsafe_root_external")" != 'outside root extra must remain unchanged' ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: unsafe payload-root extra changed an external file' >&2
  boundary_failures=1
fi

unsafe_metadata_output="$OUT/unsafe-metadata-extra-output"
unsafe_metadata_resources="$OUT/unsafe-metadata-extra-resources"
unsafe_metadata_external="$OUT/unsafe-metadata-extra-external"
unsafe_metadata_log="$OUT/unsafe-metadata-extra.log"
mkdir -p "$unsafe_metadata_output/metadata"
make_resource_fixture "$unsafe_metadata_resources"
printf '%s\n' 'outside metadata extra must remain unchanged' > "$unsafe_metadata_external"
ln -s "$unsafe_metadata_external" "$unsafe_metadata_output/metadata/unlisted-metadata-link"
set +e
run_refresh "$unsafe_metadata_output" "$unsafe_metadata_log" "$unsafe_metadata_resources"
unsafe_metadata_status=$?
set -e
if [[ "$unsafe_metadata_status" -ne 65 || -e "$unsafe_metadata_output/apps/Codex-arm64.dmg" ]]; then
  printf 'payload-refresh-tests: FAIL: unsafe metadata extra was not rejected before mutation (got %s)\n' "$unsafe_metadata_status" >&2
  cat "$unsafe_metadata_log" >&2
  boundary_failures=1
fi
if [[ "$(cat "$unsafe_metadata_external")" != 'outside metadata extra must remain unchanged' ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: unsafe metadata extra changed an external file' >&2
  boundary_failures=1
fi

plugin_catalog_race_output="$OUT/plugin-catalog-race-output"
plugin_catalog_race_resources="$OUT/plugin-catalog-race-resources"
plugin_catalog_race_log="$OUT/plugin-catalog-race.log"
plugin_catalog_expected="$OUT/plugin-catalog-race-expected.json"
make_resource_fixture "$plugin_catalog_race_resources"
cp "$plugin_catalog_race_resources/plugin-catalog.json" "$plugin_catalog_expected"
if ! PLUGIN_CATALOG_SOURCE_TO_MUTATE="$plugin_catalog_race_resources/plugin-catalog.json" \
  run_refresh "$plugin_catalog_race_output" "$plugin_catalog_race_log" "$plugin_catalog_race_resources"; then
  printf '%s\n' 'payload-refresh-tests: FAIL: staged plugin-catalog refresh failed' >&2
  boundary_failures=1
elif ! /usr/bin/cmp -s "$plugin_catalog_expected" "$plugin_catalog_race_output/plugin-catalog.json"; then
  printf '%s\n' 'payload-refresh-tests: FAIL: refresh published a plugin catalog different from the validated source snapshot' >&2
  boundary_failures=1
fi

stale_root_output="$OUT/stale-root-output"
stale_root_resources="$OUT/stale-root-resources"
stale_root_log="$OUT/stale-root.log"
mkdir -p "$stale_root_output/metadata"
make_resource_fixture "$stale_root_resources"
printf '%s\n' 'stale root file' > "$stale_root_output/unlisted-root.txt"
printf '%s\n' 'stale metadata file' > "$stale_root_output/metadata/unlisted-metadata.txt"
if ! run_refresh "$stale_root_output" "$stale_root_log" "$stale_root_resources"; then
  printf '%s\n' 'payload-refresh-tests: FAIL: refresh rejected safe stale root extras' >&2
  boundary_failures=1
elif [[ -e "$stale_root_output/unlisted-root.txt" || -e "$stale_root_output/metadata/unlisted-metadata.txt" ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: refresh retained safe stale root or metadata extras' >&2
  boundary_failures=1
fi

validation_output="$OUT/model-validation-output"
validation_resources="$OUT/model-validation-resources"
validation_log="$OUT/model-validation.log"
mkdir -p "$validation_output"
make_resource_fixture "$validation_resources"
printf '%s\n' 'published catalog must survive failed validation' > "$validation_output/model-catalog.json"
printf '%s\n' 'stale root file must survive failed validation' > "$validation_output/unlisted-root.txt"
published_catalog_sha="$(shasum -a 256 "$validation_output/model-catalog.json" | awk '{print $1}')"
resource_catalog_sha="$(shasum -a 256 "$validation_resources/model-catalog.json" | awk '{print $1}')"
set +e
MODEL_CATALOG_VALIDATE_FAIL=1 run_refresh "$validation_output" "$validation_log" "$validation_resources"
validation_status=$?
set -e
if [[ "$validation_status" -ne 65 ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: invalid staged model catalog was published' >&2
  boundary_failures=1
fi
if [[ "$(shasum -a 256 "$validation_output/model-catalog.json" | awk '{print $1}')" != "$published_catalog_sha" \
   || "$(shasum -a 256 "$validation_resources/model-catalog.json" | awk '{print $1}')" != "$resource_catalog_sha" ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: failed model validation changed a published catalog' >&2
  boundary_failures=1
fi
if [[ ! -f "$validation_output/unlisted-root.txt" ]]; then
  printf '%s\n' 'payload-refresh-tests: FAIL: failed model validation deleted a stale root file' >&2
  boundary_failures=1
fi

[[ "$boundary_failures" == 0 ]] || exit 1

outside_apps="$OUT/outside-apps"
unsafe_output="$OUT/unsafe-output"
mkdir -p "$outside_apps" "$unsafe_output/sources"
printf '%s\n' 'outside arm64 payload must remain unchanged' > "$outside_apps/Codex-arm64.dmg"
ln -s "$outside_apps" "$unsafe_output/apps"
unsafe_log="$OUT/unsafe-output.log"
set +e
run_refresh "$unsafe_output" "$unsafe_log"
unsafe_status=$?
set -e
[[ "$unsafe_status" -eq 65 ]] || fail 'payload apps symlink did not exit 65'
[[ "$(cat "$outside_apps/Codex-arm64.dmg")" == 'outside arm64 payload must remain unchanged' \
   && ! -e "$outside_apps/Codex-x64.dmg" ]] \
  || fail 'payload apps symlink allowed a write outside the payload tree'

outside_marker="$OUT/outside-marker"
mkdir -p "$outside_marker"
printf '%s\n' 'outside marker must remain unchanged' > "$outside_marker/marker"
symlink_output="$OUT/symlink-output"
mkdir -p "$symlink_output/apps"
ln -s "$outside_marker/marker" "$symlink_output/apps/stale-link"
symlink_log="$OUT/symlink-output.log"
set +e
run_refresh "$symlink_output" "$symlink_log"
symlink_status=$?
set -e
[[ "$symlink_status" -eq 65 ]] || fail 'unexpected payload symlink did not exit 65'
[[ "$(cat "$outside_marker/marker")" == 'outside marker must remain unchanged' ]] \
  || fail 'unexpected payload symlink changed a file outside the payload tree'

nonregular_output="$OUT/nonregular-output"
mkdir -p "$nonregular_output/apps" "$nonregular_output/sources/stale-directory"
printf '%s\n' 'stale app marker must survive source validation failure' > "$nonregular_output/apps/stale-app-marker"
nonregular_log="$OUT/nonregular-output.log"
set +e
run_refresh "$nonregular_output" "$nonregular_log"
nonregular_status=$?
set -e
[[ "$nonregular_status" -eq 65 ]] || fail 'unexpected payload directory did not exit 65'
[[ "$(cat "$outside_marker/marker")" == 'outside marker must remain unchanged' ]] \
  || fail 'unexpected payload directory changed a file outside the payload tree'
[[ -f "$nonregular_output/apps/stale-app-marker" ]] \
  || fail 'source validation failure deleted a stale app marker'

enumeration_output="$OUT/enumeration-output"
enumeration_log="$OUT/enumeration-output.log"
set +e
PAYLOAD_FIND_BIN="$FAKE_PAYLOAD_FIND" run_refresh "$enumeration_output" "$enumeration_log"
enumeration_status=$?
set -e
[[ "$enumeration_status" -eq 65 ]] || fail 'payload entry enumeration failure was silently accepted'
rg -Fq 'unable to enumerate payload directory' "$enumeration_log" \
  || fail 'payload entry enumeration failure explanation missing'

printf '%s\n' 'chatgpt-arm64-dmg-v2' > "$HTTP_DIR/Codex-arm64.dmg"
printf '%s\n' 'chatgpt-x64-dmg-v2' > "$HTTP_DIR/Codex-x64.dmg"
printf '%s\n' 'stale arm64 artifact' > "$OUTPUT_ROOT/apps/CodexPlusPlus-0.0.1-macos-arm64.dmg"
printf '%s\n' 'stale x64 artifact' > "$OUTPUT_ROOT/apps/CodexPlusPlus-0.0.1-macos-x64.dmg"
printf '%s\n' 'stale source artifact' > "$OUTPUT_ROOT/sources/CodexPlusPlus-v0.0.1.tar.gz"
: > "$CAPTURE_DIR/curl.log"
repeat_refresh_log="$OUT/repeat-refresh.log"
run_refresh "$OUTPUT_ROOT" "$repeat_refresh_log"
[[ "$(cat "$OUTPUT_ROOT/apps/Codex-arm64.dmg")" == 'chatgpt-arm64-dmg-v2' ]] \
  || fail 'mutable ChatGPT arm64 latest URL reused stale cache'
[[ "$(cat "$OUTPUT_ROOT/apps/Codex-x64.dmg")" == 'chatgpt-x64-dmg-v2' ]] \
  || fail 'mutable ChatGPT x64 latest URL reused stale cache'
rg -Fq 'https://persistent.oaistatic.com/codex-app-prod/Codex.dmg' "$CAPTURE_DIR/curl.log" \
  || fail 'second refresh did not request current ChatGPT arm64 payload'
! rg -Fq 'https://downloads.invalid/CodexPlusPlus-9.8.7-macos-arm64.dmg' "$CAPTURE_DIR/curl.log" \
  || fail 'second refresh re-downloaded cached Codex++ arm64 payload'
! rg -Fq 'https://downloads.invalid/CodexPlusPlus-9.8.7-macos-x64.dmg' "$CAPTURE_DIR/curl.log" \
  || fail 'second refresh re-downloaded cached Codex++ x64 payload'
! rg -Fq 'https://github.com/BigPizzaV3/CodexPlusPlus/archive/refs/tags/v9.8.7.tar.gz' "$CAPTURE_DIR/curl.log" \
  || fail 'second refresh re-downloaded cached Codex++ source payload'
[[ ! -e "$OUTPUT_ROOT/apps/CodexPlusPlus-0.0.1-macos-arm64.dmg" \
   && ! -e "$OUTPUT_ROOT/apps/CodexPlusPlus-0.0.1-macos-x64.dmg" \
   && ! -e "$OUTPUT_ROOT/sources/CodexPlusPlus-v0.0.1.tar.gz" ]] \
  || fail 'stale versioned Codex++ payload survived exact snapshot refresh'

split_output="$OUT/split-output"
split_log="$OUT/split.log"
set +e
APP_INSPECT_SPLIT=1 run_refresh "$split_output" "$split_log"
split_status=$?
set -e
[[ "$split_status" -eq 66 ]] || fail 'split-architecture Codex++ DMG did not exit 66'
rg -Fq 'Codex++ arm64 DMG identity is invalid' "$split_log" \
  || fail 'split-architecture Codex++ explanation missing'

while IFS=$'\t' read -r marketplace plugin; do
  plugin_json="$(find "$OUTPUT_ROOT/plugins/cache/$marketplace/$plugin" -path '*/.codex-plugin/plugin.json' -type f -print -quit)"
  [[ -n "$plugin_json" ]] || fail "plugin cache missing: $plugin@$marketplace"
done < <(jq -r '.plugins[] | [.marketplace,.id] | @tsv' "$RESOURCE_DIR/plugin-catalog.json")
[[ "$(jq -r '.files | length' "$OUTPUT_ROOT/plugins/file-manifest.json")" -gt 20 ]] || fail 'plugin file manifest incomplete'
plugin_manifest_count="$(jq -r '.files | length' "$OUTPUT_ROOT/plugins/file-manifest.json")"
plugin_actual_count="$(find "$OUTPUT_ROOT/plugins/marketplaces" "$OUTPUT_ROOT/plugins/cache" -type f | wc -l | tr -d ' ')"
[[ "$plugin_manifest_count" == "$plugin_actual_count" ]] || fail 'plugin manifest file set mismatch'
while IFS=$'\t' read -r relative expected; do
  actual="$(shasum -a 256 "$OUTPUT_ROOT/plugins/$relative" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || fail "plugin file hash mismatch: $relative"
done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$OUTPUT_ROOT/plugins/file-manifest.json")

deep_sha="$(printf '%s' "$deep_key" | shasum -a 256 | awk '{print $1}')"
kimi_sha="$(printf '%s' "$kimi_key" | shasum -a 256 | awk '{print $1}')"
rg -q "deepseek $deep_sha" "$CAPTURE_DIR/model-key-shas.txt" || fail 'DeepSeek Key not delivered through stdin'
rg -q "kimi-open $kimi_sha" "$CAPTURE_DIR/model-key-shas.txt" || fail 'Kimi Key not delivered through stdin'
if rg -F "$deep_key" "$manifest" "$refresh_log" "$CAPTURE_DIR/curl.log" "$CAPTURE_DIR/model-providers.txt" >/dev/null || \
   rg -F "$kimi_key" "$manifest" "$refresh_log" "$CAPTURE_DIR/curl.log" "$CAPTURE_DIR/model-providers.txt" >/dev/null; then
  fail 'catalog Key leaked to manifest or log'
fi

mismatched_zh_sha='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
jq --arg sha "$mismatched_zh_sha" \
  '(.scripts[] | select(.id == "codex-zhcn-translate") | .sha256) = $sha' \
  "$HTTP_DIR/script-index.json" > "$HTTP_DIR/script-index.mismatched.json"
mv "$HTTP_DIR/script-index.mismatched.json" "$HTTP_DIR/script-index.json"
printf '%s\n' '{"schemaVersion":2,"overrides":[]}' > "$RESOURCE_DIR/script-market-overrides.json"
: > "$CAPTURE_DIR/curl.log"
unaudited_output="$OUT/unaudited-output"
unaudited_log="$OUT/unaudited.log"
set +e
run_refresh "$unaudited_output" "$unaudited_log"
unaudited_status=$?
set -e
[[ "$unaudited_status" -eq 68 ]] || fail 'unaudited script mismatch did not exit 68'
rg -q 'script payload hash mismatch: codex-zhcn-translate' "$unaudited_log" \
  || fail 'unaudited script mismatch explanation missing'
! rg -q '/commits/|/contents/|https://raw\.githubusercontent\.com/example/market/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/scripts/zh\.js' "$CAPTURE_DIR/curl.log" \
  || fail 'unaudited script mismatch contacted an alternate upstream'

pinned_zh_url='https://raw.githubusercontent.com/example/market/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/scripts/zh.js'
pinned_zh_commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jq -n \
  --arg id 'codex-zhcn-translate' \
  --arg upstream_url 'https://raw.githubusercontent.com/example/market/main/scripts/zh.js' \
  --arg upstream_sha "$mismatched_zh_sha" \
  --arg pinned_url "$pinned_zh_url" \
  --arg pinned_sha "$zh_sha" \
  --arg source_commit "$pinned_zh_commit" \
  '{schemaVersion:2,overrides:[{mode:"pinned",id:$id,upstreamURL:$upstream_url,upstreamSHA256:$upstream_sha,pinnedURL:$pinned_url,pinnedSHA256:$pinned_sha,sourceCommit:$source_commit}]}' \
  > "$RESOURCE_DIR/script-market-overrides.json"
: > "$CAPTURE_DIR/curl.log"
audited_output="$OUT/audited-output"
audited_log="$OUT/audited.log"
run_refresh "$audited_output" "$audited_log"
rg -Fx "$pinned_zh_url" "$CAPTURE_DIR/curl.log" >/dev/null || fail 'audited script mismatch did not use pinned URL'
! rg -q '/commits/|/contents/' "$CAPTURE_DIR/curl.log" \
  || fail 'audited script mismatch contacted a legacy GitHub metadata endpoint'
[[ "$(jq -r '.scripts[] | select(.id == "codex-zhcn-translate") | .sha256' "$audited_output/script-market/index.json")" == "$zh_sha" ]] \
  || fail 'audited script hash was not pinned exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-zhcn-translate") | .upstream_sha256' "$audited_output/script-market/index.json")" == "$mismatched_zh_sha" ]] \
  || fail 'audited upstream script hash was not recorded exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-zhcn-translate") | .source_commit' "$audited_output/script-market/index.json")" == "$pinned_zh_commit" ]] \
  || fail 'audited source commit was not recorded exactly'
[[ "$(jq -r '.scripts[] | select(.id == "codex-zhcn-translate") | .script_url' "$audited_output/script-market/index.json")" == "$pinned_zh_url" ]] \
  || fail 'audited pinned script URL was not recorded exactly'

jq -n \
  --arg id 'codex-zhcn-translate' \
  --arg upstream_url 'https://raw.githubusercontent.com/example/market/main/scripts/zh.js' \
  --arg upstream_sha 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
  --arg pinned_url "$pinned_zh_url" \
  --arg pinned_sha "$zh_sha" \
  --arg source_commit "$pinned_zh_commit" \
  '{schemaVersion:2,overrides:[{mode:"pinned",id:$id,upstreamURL:$upstream_url,upstreamSHA256:$upstream_sha,pinnedURL:$pinned_url,pinnedSHA256:$pinned_sha,sourceCommit:$source_commit}]}' \
  > "$RESOURCE_DIR/script-market-overrides.json"
: > "$CAPTURE_DIR/curl.log"
stale_lock_output="$OUT/stale-lock-output"
stale_lock_log="$OUT/stale-lock.log"
set +e
run_refresh "$stale_lock_output" "$stale_lock_log"
stale_lock_status=$?
set -e
[[ "$stale_lock_status" -eq 68 ]] || fail 'stale script override lock did not exit 68'
rg -q 'script payload hash mismatch: codex-zhcn-translate' "$stale_lock_log" \
  || fail 'stale script override lock mismatch explanation missing'
! rg -Fq "$pinned_zh_url" "$CAPTURE_DIR/curl.log" \
  || fail 'stale script override lock downloaded the pinned URL'
! rg -q '/commits/|/contents/' "$CAPTURE_DIR/curl.log" \
  || fail 'stale script override lock contacted a legacy GitHub metadata endpoint'

THIN_OUTPUT="$OUT/thin-output"
set +e
thin_log="$(
  DEEPSEEK_CATALOG_KEY="$deep_key" \
  KIMI_OPEN_CATALOG_KEY="$kimi_key" \
  TEST_MODE=1 APP_INSPECT_THIN=1 \
  CURL_BIN="$FAKE_CURL" APP_INSPECT_BIN="$FAKE_INSPECT" SUPPORT_TOOL="$FAKE_SUPPORT" \
  BUILDER_HOME="$BUILDER_HOME" OUTPUT_ROOT="$THIN_OUTPUT" RESOURCE_DIR_OVERRIDE="$RESOURCE_DIR" \
  GENERATED_AT_OVERRIDE='2026-07-21T12:00:00Z' \
  bash "$ROOT/scripts/refresh-offline-payloads.sh" 2>&1
)"
thin_status=$?
set -e
[[ "$thin_status" -eq 66 ]] || fail 'thin Codex DMG did not exit 66'
[[ "$thin_log" == *'x86_64'* ]] || fail 'wrong-architecture Codex explanation missing'

MISSING_PLUGIN_HOME="$OUT/missing-plugin-home"
/usr/bin/ditto "$BUILDER_HOME" "$MISSING_PLUGIN_HOME"
/bin/rm -R "$MISSING_PLUGIN_HOME/.codex/plugins/cache/openai-curated/github"
MISSING_PLUGIN_OUTPUT="$OUT/missing-plugin-output"
set +e
missing_plugin_log="$(
  DEEPSEEK_CATALOG_KEY="$deep_key" \
  KIMI_OPEN_CATALOG_KEY="$kimi_key" \
  TEST_MODE=1 \
  CURL_BIN="$FAKE_CURL" APP_INSPECT_BIN="$FAKE_INSPECT" SUPPORT_TOOL="$FAKE_SUPPORT" \
  BUILDER_HOME="$MISSING_PLUGIN_HOME" OUTPUT_ROOT="$MISSING_PLUGIN_OUTPUT" RESOURCE_DIR_OVERRIDE="$RESOURCE_DIR" \
  GENERATED_AT_OVERRIDE='2026-07-21T12:00:00Z' \
  bash "$ROOT/scripts/refresh-offline-payloads.sh" 2>&1
)"
missing_plugin_status=$?
set -e
[[ "$missing_plugin_status" -eq 67 ]] || fail 'missing plugin did not exit 67'
[[ "$missing_plugin_log" == *'missing plugin cache github@openai-curated'* ]] || fail 'missing plugin exact ID not reported'

printf '%s\n' 'payload-refresh-tests: PASS'
