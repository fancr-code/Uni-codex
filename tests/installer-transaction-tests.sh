#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(mktemp -d "$TEST_TMPDIR/codex-transaction-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

fail() {
  printf 'installer-transaction-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

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
  -o "$OUT/installer-support"

PAYLOAD_ROOT="$OUT/payloads"
APPLICATIONS_DIR="$OUT/Applications"
REPORT_DIR="$OUT/reports"
mkdir -p "$PAYLOAD_ROOT" "$APPLICATIONS_DIR" "$REPORT_DIR"
NO_JQ_BIN="$OUT/no-jq-bin"
NO_JQ_MARKER="$OUT/jq-was-invoked"
mkdir -p "$NO_JQ_BIN"
printf '%s\n' '#!/bin/sh' ': > "${NO_JQ_MARKER:?}"' 'exit 99' > "$NO_JQ_BIN/jq"
chmod 700 "$NO_JQ_BIN/jq"
cp "$ROOT/tests/fixtures/payload-manifest.test.json" "$PAYLOAD_ROOT/payload-manifest.json"
cp "$ROOT/Resources/model-catalog.json" "$PAYLOAD_ROOT/model-catalog.json"
/usr/bin/ditto "$ROOT/tests/fixtures/apps" "$PAYLOAD_ROOT/apps"
/usr/bin/ditto "$ROOT/tests/fixtures/script-market" "$PAYLOAD_ROOT/script-market"
printf '%s\n' 'window.fourthPayloadScript = true;' \
  > "$PAYLOAD_ROOT/script-market/scripts/fourth-payload-script.js"
fourth_script_sha="$(/usr/bin/shasum -a 256 \
  "$PAYLOAD_ROOT/script-market/scripts/fourth-payload-script.js" | /usr/bin/awk '{print $1}')"
jq --arg sha "$fourth_script_sha" \
  '.scripts += [{
    "id":"fourth-payload-script",
    "name":"Fourth Payload Script",
    "version":"1.0.0",
    "homepage":"https://example.com/fourth-payload-script",
    "script_url":"https://example.com/fourth-payload-script.js",
    "sha256":$sha
  }]' \
  "$PAYLOAD_ROOT/script-market/index.json" \
  > "$PAYLOAD_ROOT/script-market/index.tmp"
mv "$PAYLOAD_ROOT/script-market/index.tmp" "$PAYLOAD_ROOT/script-market/index.json"

cp "$ROOT/Resources/plugin-catalog.json" "$PAYLOAD_ROOT/plugin-catalog.json"
for marketplace in openai-bundled openai-primary-runtime openai-curated; do
  mkdir -p "$PAYLOAD_ROOT/plugins/marketplaces/$marketplace/.agents/plugins"
  printf '%s\n' '{"name":"test-marketplace"}' \
    > "$PAYLOAD_ROOT/plugins/marketplaces/$marketplace/.agents/plugins/marketplace.json"
done
while IFS='|' read -r marketplace plugin; do
  plugin_version_root="$PAYLOAD_ROOT/plugins/cache/$marketplace/$plugin/1.0.0"
  mkdir -p "$plugin_version_root/.codex-plugin"
  printf '{"name":"%s","version":"1.0.0"}\n' "$plugin" \
    > "$plugin_version_root/.codex-plugin/plugin.json"
done <<'PLUGINS'
openai-bundled|browser
openai-bundled|chrome
openai-bundled|computer-use
openai-bundled|latex
openai-primary-runtime|pdf
openai-primary-runtime|documents
openai-primary-runtime|spreadsheets
openai-primary-runtime|presentations
openai-curated|github
PLUGINS
plugin_manifest_entries="$OUT/plugin-manifest-entries.ndjson"
: > "$plugin_manifest_entries"
while IFS= read -r plugin_file; do
  plugin_relative="${plugin_file#"$PAYLOAD_ROOT/plugins/"}"
  plugin_sha="$(/usr/bin/shasum -a 256 "$plugin_file" | /usr/bin/awk '{print $1}')"
  jq -nc --arg path "$plugin_relative" --arg sha256 "$plugin_sha" \
    '{path:$path,sha256:$sha256}' >> "$plugin_manifest_entries"
done < <(/usr/bin/find "$PAYLOAD_ROOT/plugins/marketplaces" "$PAYLOAD_ROOT/plugins/cache" \
  -type f | /usr/bin/sort)
jq -s '{schemaVersion:1,files:.}' "$plugin_manifest_entries" \
  > "$PAYLOAD_ROOT/plugins/file-manifest.json"

request='{"provider":"deepseek","apiKey":"sk-transaction-test","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"]}'
authorized_request='{"provider":"deepseek","apiKey":"sk-authorized-transaction-test","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"],"authenticationMode":"openAIAccountWithAPI"}'

assert_minimal_report() {
  local report="$1"
  local authorization="$2"
  local expected
  expected="$(printf '%s\n' \
    "OpenAI authorization: $authorization" \
    'Context Used Meter: 101 · enabled · runtime-smoke-pass' \
    'Codex Token Usage: 0.1.7 · enabled · runtime-smoke-pass')"
  [[ "$(< "$report")" == "$expected" ]] || fail 'success report contains data beyond its three status lines'
  ! rg -q 'Provider|默认模型|ChatGPT/Codex|Codex\+\+|插件市场|汉化脚本|备份：|检查时间|系统：|API Key 连通性|deepseek-v4-pro|arm64|26\.715\.52143|sk-|[0-9a-f]{64}' "$report" \
    || fail 'success report exposes legacy detail or a sensitive sample'
}

prepare_home() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex" "$home_dir/.codex-session-delete"
  printf '%s\n' 'model = "original"' 'user_setting = "preserve"' > "$home_dir/.codex/config.toml"
  printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"official"}}' > "$home_dir/.codex/auth.json"
  printf '%s\n' '{"userSetting":true,"relayProfiles":[]}' > "$home_dir/.codex-session-delete/settings.json"
}

run_core_for_home() {
  local home_dir="$1"
  shift
  local selected_architecture="${REAL_ARCH_OVERRIDE:-arm64}"
  local selected_applications_dir="${APPLICATIONS_DIR_OVERRIDE:-$APPLICATIONS_DIR}"
  local selected_payload_root="${PAYLOAD_ROOT_OVERRIDE:-$PAYLOAD_ROOT}"
  local selected_report_dir="${REPORT_DIR_OVERRIDE:-$REPORT_DIR}"
  TEST_MODE=1 \
  HOME="$home_dir" \
  APPLICATIONS_DIR="$selected_applications_dir" \
  PAYLOAD_ROOT="$selected_payload_root" \
  REPORT_DIR="$selected_report_dir" \
  SUPPORT_TOOL="$OUT/installer-support" \
  NO_JQ_MARKER="$NO_JQ_MARKER" \
  PATH="$NO_JQ_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  REAL_ARCH_OVERRIDE="$selected_architecture" \
  MACOS_VERSION_OVERRIDE=14.6 \
  DISK_BYTES_OVERRIDE=10000000000 \
  bash "$ROOT/Resources/installer-core.sh" "$@"
}

ROLLBACK_HOME="$OUT/rollback-home"
prepare_home "$ROLLBACK_HOME"
cp "$ROLLBACK_HOME/.codex/config.toml" "$OUT/original-config.toml"
cp "$ROLLBACK_HOME/.codex/auth.json" "$OUT/original-auth.json"
cp "$ROLLBACK_HOME/.codex-session-delete/settings.json" "$OUT/original-settings.json"

set +e
rollback_output="$(printf '%s' "$request" | FAIL_AFTER_CONFIG=1 run_core_for_home "$ROLLBACK_HOME" install --request-stdin 2>&1)"
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]]
[[ "$rollback_output" == *'rollback_completed'* ]]
cmp "$OUT/original-config.toml" "$ROLLBACK_HOME/.codex/config.toml"
cmp "$OUT/original-auth.json" "$ROLLBACK_HOME/.codex/auth.json"
cmp "$OUT/original-settings.json" "$ROLLBACK_HOME/.codex-session-delete/settings.json"
[[ ! -e "$APPLICATIONS_DIR/ChatGPT.app" ]]
[[ ! -e "$APPLICATIONS_DIR/Codex++.app" ]]
[[ ! -e "$APPLICATIONS_DIR/Codex++ 管理工具.app" ]]
[[ ! -e "$ROLLBACK_HOME/.config/Codex++/user_scripts.json" ]]
[[ ! -e "$ROLLBACK_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json" ]]
rollback_preflight="$(run_core_for_home "$ROLLBACK_HOME" preflight)"
[[ "$rollback_preflight" == *'"latestBackup":null'* ]] || {
  printf '%s\n' 'installer-transaction-tests: FAIL: failed install exposed an incomplete backup as latest' >&2
  exit 1
}

SUCCESS_HOME="$OUT/success-home"
SUCCESS_APPLICATIONS="$OUT/success-Applications"
prepare_home "$SUCCESS_HOME"
mkdir -p \
  "$SUCCESS_APPLICATIONS/ChatGPT.app" \
  "$SUCCESS_APPLICATIONS/Codex++.app" \
  "$SUCCESS_APPLICATIONS/Codex++ 管理工具.app" \
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-bundled" \
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-primary-runtime" \
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-curated" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/browser" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/chrome" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/computer-use" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/latex" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/pdf" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/documents" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/spreadsheets" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/presentations" \
  "$SUCCESS_HOME/.codex/plugins/cache/openai-curated/github" \
  "$SUCCESS_HOME/.codex/plugins/cache/user-market/custom-plugin" \
  "$SUCCESS_HOME/.config/Codex++/user_scripts"

managed_directories=(
  "$SUCCESS_APPLICATIONS/ChatGPT.app"
  "$SUCCESS_APPLICATIONS/Codex++.app"
  "$SUCCESS_APPLICATIONS/Codex++ 管理工具.app"
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-bundled"
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-primary-runtime"
  "$SUCCESS_HOME/.codex/offline-marketplaces/openai-curated"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/browser"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/chrome"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/computer-use"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-bundled/latex"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/pdf"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/documents"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/spreadsheets"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-primary-runtime/presentations"
  "$SUCCESS_HOME/.codex/plugins/cache/openai-curated/github"
)
managed_index=0
for managed_directory in "${managed_directories[@]}"; do
  managed_index=$((managed_index + 1))
  printf 'original-managed-%s\n' "$managed_index" > "$managed_directory/original-marker"
done
printf '%s\n' '{"enabled":false,"scripts":{"user:manual.js":false,"user:market-codex-token-usage.js":false},"private":true}' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts.json"
printf '%s\n' 'original-translation' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"
printf '%s\n' 'original-meter' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-context-used-meter.js"
printf '%s\n' 'original-token-usage' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-token-usage.js"
printf '%s\n' 'original-custom-market-script' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-custom.js"
printf '%s\n' 'unrelated-script' > "$SUCCESS_HOME/.config/Codex++/user_scripts/manual.js"
printf '%s\n' 'unrelated-plugin' > "$SUCCESS_HOME/.codex/plugins/cache/user-market/custom-plugin/marker"
mkdir -p "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer"
printf '%s\n' 'original-install-expectation' \
  > "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json"

cp "$SUCCESS_HOME/.codex/config.toml" "$OUT/success-original-config.toml"
cp "$SUCCESS_HOME/.codex/auth.json" "$OUT/success-original-auth.json"
cp "$SUCCESS_HOME/.codex-session-delete/settings.json" "$OUT/success-original-settings.json"
cp "$SUCCESS_HOME/.config/Codex++/user_scripts.json" "$OUT/success-original-user-scripts.json"
cp "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json" \
  "$OUT/success-original-install-expectation.json"

success_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" run_core_for_home "$SUCCESS_HOME" install --request-stdin 2>&1)"
[[ "$success_output" == *'install_completed'* ]]
rg -q 'model = "deepseek-v4-pro"' "$SUCCESS_HOME/.codex/config.toml"
[[ "$(jq -r '.OPENAI_API_KEY' "$SUCCESS_HOME/.codex/auth.json")" == 'sk-transaction-test' ]]
[[ "$(< "$SUCCESS_APPLICATIONS/ChatGPT.app/Contents/test-architecture")" == 'arm64' ]]
[[ "$(< "$SUCCESS_APPLICATIONS/Codex++.app/Contents/test-architecture")" == 'arm64' ]]
[[ "$(< "$SUCCESS_APPLICATIONS/Codex++ 管理工具.app/Contents/test-architecture")" == 'arm64' ]]
[[ "$(jq -r '.scripts["user:market-codex-zhcn-translate.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-context-used-meter.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-token-usage.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-daily-token-usage.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == false ]]
[[ "$(jq -r '.scripts["user:market-codex-live-token-cost.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == false ]]
[[ "$(jq -r '.scripts["user:market-another-script.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == false ]]
[[ -f "$SUCCESS_HOME/.config/Codex++/user_scripts/market-another-script.js" ]]
[[ -f "$SUCCESS_HOME/.config/Codex++/user_scripts/market-fourth-payload-script.js" ]]
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/market-custom.js")" == 'original-custom-market-script' ]] || \
  fail 'installation altered an unrelated custom market script'
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/manual.js")" == 'unrelated-script' ]]
[[ "$(< "$SUCCESS_HOME/.codex/plugins/cache/user-market/custom-plugin/marker")" == 'unrelated-plugin' ]]
expectation_path="$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json"
[[ -f "$expectation_path" ]]
expectation_hash="$(/usr/bin/plutil -extract apiKeySHA256 raw -o - "$expectation_path")"
[[ "$expectation_hash" =~ ^[0-9a-f]{64}$ ]]
! rg -q 'sk-transaction-test' "$expectation_path"
success_report="$(find "$REPORT_DIR" -name 'install-report-*.md' -type f | sort | tail -n 1)"
[[ -f "$success_report" ]]
assert_minimal_report "$success_report" skipped

AUTHORIZED_HOME="$OUT/authorized-home"
AUTHORIZED_APPLICATIONS="$OUT/authorized-Applications"
AUTHORIZED_REPORT_DIR="$OUT/authorized-reports"
prepare_home "$AUTHORIZED_HOME"
mkdir -p "$AUTHORIZED_APPLICATIONS" "$AUTHORIZED_REPORT_DIR"
authorized_output="$(printf '%s' "$authorized_request" | \
  APPLICATIONS_DIR_OVERRIDE="$AUTHORIZED_APPLICATIONS" \
  REPORT_DIR_OVERRIDE="$AUTHORIZED_REPORT_DIR" \
  run_core_for_home "$AUTHORIZED_HOME" install --request-stdin 2>&1)"
[[ "$authorized_output" == *'install_completed'* ]]
authorized_report="$(find "$AUTHORIZED_REPORT_DIR" -name 'install-report-*.md' -type f | sort | tail -n 1)"
[[ -f "$authorized_report" ]]
assert_minimal_report "$authorized_report" authorized

cp "$SUCCESS_HOME/.codex/config.toml" "$OUT/semantic-valid-config.toml"
cp "$SUCCESS_HOME/.codex/auth.json" "$OUT/semantic-valid-auth.json"
cp "$SUCCESS_HOME/.codex-session-delete/settings.json" "$OUT/semantic-valid-settings.json"
cp "$SUCCESS_HOME/.config/Codex++/user_scripts.json" "$OUT/semantic-valid-scripts.json"
cp "$SUCCESS_APPLICATIONS/ChatGPT.app/Contents/Info.plist" "$OUT/semantic-valid-chatgpt-info.plist"

/usr/bin/sed 's/^model = "deepseek-v4-pro"$/model = "wrong-model"/' \
  "$OUT/semantic-valid-config.toml" > "$SUCCESS_HOME/.codex/config.toml"
set +e
wrong_model_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
wrong_model_status=$?
set -e
[[ "$wrong_model_status" -eq 67 ]]
[[ "$wrong_model_output" == *'"code":"configuration_verify_failed"'* ]]
[[ "$wrong_model_output" == *'"configuration":{"status":"fail"'* ]]
[[ "$wrong_model_output" != *'sk-transaction-test'* && "$wrong_model_output" != *"$expectation_hash"* ]]
cp "$OUT/semantic-valid-config.toml" "$SUCCESS_HOME/.codex/config.toml"

jq '.OPENAI_API_KEY = "sk-wrong-transaction-key"' \
  "$OUT/semantic-valid-auth.json" > "$SUCCESS_HOME/.codex/auth.json"
set +e
wrong_key_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
wrong_key_status=$?
set -e
[[ "$wrong_key_status" -eq 67 ]]
[[ "$wrong_key_output" == *'"code":"configuration_verify_failed"'* ]]
[[ "$wrong_key_output" != *'sk-wrong-transaction-key'* && "$wrong_key_output" != *"$expectation_hash"* ]]
cp "$OUT/semantic-valid-auth.json" "$SUCCESS_HOME/.codex/auth.json"

jq '.activeRelayId = "wrong-relay"' \
  "$OUT/semantic-valid-settings.json" > "$SUCCESS_HOME/.codex-session-delete/settings.json"
set +e
wrong_relay_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
wrong_relay_status=$?
set -e
[[ "$wrong_relay_status" -eq 67 ]]
[[ "$wrong_relay_output" == *'"code":"configuration_verify_failed"'* ]]
cp "$OUT/semantic-valid-settings.json" "$SUCCESS_HOME/.codex-session-delete/settings.json"

for metadata_script in \
  user:market-codex-context-used-meter.js \
  user:market-codex-token-usage.js; do
  jq --arg script "$metadata_script" \
    '.market[$script].version = "999"' \
    "$OUT/semantic-valid-scripts.json" > "$SUCCESS_HOME/.config/Codex++/user_scripts.json"
  set +e
  metadata_version_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
    run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
  metadata_version_status=$?
  set -e
  [[ "$metadata_version_status" -eq 67 ]] || fail "metadata version mismatch passed verification for $metadata_script"
  [[ "$metadata_version_output" == *'"code":"script_verify_failed"'* ]] || \
    fail "metadata version mismatch used the wrong verification failure for $metadata_script"
done
cp "$OUT/semantic-valid-scripts.json" "$SUCCESS_HOME/.config/Codex++/user_scripts.json"

/usr/bin/sed \
  '/^\[plugins\."browser@openai-bundled"\]/,/^\[/ s/^enabled = true$/enabled = false/' \
  "$OUT/semantic-valid-config.toml" > "$SUCCESS_HOME/.codex/config.toml"
set +e
disabled_plugin_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
disabled_plugin_status=$?
set -e
[[ "$disabled_plugin_status" -eq 67 ]]
[[ "$disabled_plugin_output" == *'"code":"plugin_verify_failed"'* ]]
[[ "$disabled_plugin_output" == *'"plugins":{"status":"fail"'* ]]
cp "$OUT/semantic-valid-config.toml" "$SUCCESS_HOME/.codex/config.toml"

printf '%s\n' 'modified-managed-token-usage' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-token-usage.js"
set +e
modified_script_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
modified_script_status=$?
set -e
[[ "$modified_script_status" -eq 67 ]]
[[ "$modified_script_output" == *'"code":"script_verify_failed"'* ]]
/bin/cp "$PAYLOAD_ROOT/script-market/scripts/codex-token-usage.js" \
  "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-token-usage.js"

/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier invalid.bundle.identifier' \
  "$SUCCESS_APPLICATIONS/ChatGPT.app/Contents/Info.plist"
set +e
wrong_app_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
wrong_app_status=$?
set -e
[[ "$wrong_app_status" -eq 67 ]]
[[ "$wrong_app_output" == *'"code":"application_verify_failed"'* ]]
cp "$OUT/semantic-valid-chatgpt-info.plist" "$SUCCESS_APPLICATIONS/ChatGPT.app/Contents/Info.plist"

verify_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" verify 2>&1)"
[[ "$verify_output" == *'"kind":"verify_completed"'* ]]
[[ "$verify_output" == *'"overall":"pass"'* ]]
[[ "$verify_output" == *'"tokenUsageEnabled":true'* ]]
[[ "$verify_output" != *'sk-transaction-test'* && "$verify_output" != *"$expectation_hash"* ]]

complete_backup="$(find "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups" \
  -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/complete' ';' -print)"
[[ -n "$complete_backup" ]] || {
  printf '%s\n' 'installer-transaction-tests: FAIL: successful install did not finalize a complete backup' >&2
  exit 1
}
[[ "$(jq -r '.schemaVersion' "$complete_backup/inventory.json")" -eq 2 ]]
[[ "$(jq -r '.schemaVersion' "$complete_backup/configuration/inventory.json")" -eq 2 ]]
[[ "$(stat -f '%z' "$complete_backup/complete")" -eq 0 ]]
[[ "$(jq '[.entries[] | select(.key == "script.file.market-another-script.js" and .existed == false and .backupRelativePath == null)] | length' "$complete_backup/inventory.json")" -eq 1 ]]
[[ "$(jq '[.entries[] | select(.key == "script.file.market-codex-token-usage.js" and .kind == "file" and .existed == true and .backupRelativePath == "scripts/user_scripts/market-codex-token-usage.js")] | length' "$complete_backup/inventory.json")" -eq 1 ]]
[[ "$(jq '[.entries[] | select(.key == "script.file.market-custom.js" and .kind == "file" and .existed == true and .backupRelativePath == "scripts/user_scripts/market-custom.js")] | length' "$complete_backup/inventory.json")" -eq 1 ]]
[[ "$(jq '[.entries[] | select(.key == "script.file.market-fourth-payload-script.js" and .kind == "file" and .existed == false and .backupRelativePath == null)] | length' "$complete_backup/inventory.json")" -eq 1 ]] || \
  fail 'snapshot omitted an absent script introduced by the staged payload'
! rg -q 'originalPath|sk-transaction-test|/Users/|/Applications/' \
  "$complete_backup/inventory.json" "$complete_backup/configuration/inventory.json"

REPEAT_HOME="$OUT/repeat-home"
REPEAT_APPLICATIONS="$OUT/repeat-Applications"
prepare_home "$REPEAT_HOME"
mkdir -p "$REPEAT_APPLICATIONS"
printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$REPEAT_APPLICATIONS" \
  run_core_for_home "$REPEAT_HOME" install --request-stdin >/dev/null 2>&1
repeat_first_backup="$(find "$REPEAT_HOME/Library/Application Support/Codex One Click Installer/backups" \
  -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/complete' ';' -print | sort | tail -n 1)"
printf '%s\n' 'preserve-on-idempotent-run' > "$REPEAT_APPLICATIONS/ChatGPT.app/user-marker"
repeat_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$REPEAT_APPLICATIONS" run_core_for_home "$REPEAT_HOME" install --request-stdin 2>&1)"
[[ "$repeat_output" == *'skipped_app'* ]]
[[ -f "$REPEAT_APPLICATIONS/ChatGPT.app/user-marker" ]]
repeat_second_backup="$(find "$REPEAT_HOME/Library/Application Support/Codex One Click Installer/backups" \
  -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/complete' ';' -print | sort | tail -n 1)"
[[ "$repeat_second_backup" > "$repeat_first_backup" ]]

ATOMIC_HOME="$OUT/atomic-home"
ATOMIC_APPLICATIONS="$OUT/atomic-Applications"
prepare_home "$ATOMIC_HOME"
mkdir -p "$ATOMIC_APPLICATIONS"
printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$ATOMIC_APPLICATIONS" \
  run_core_for_home "$ATOMIC_HOME" install --request-stdin >/dev/null 2>&1
printf '%s\n' 'launcher-must-be-replaced-with-pair' \
  > "$ATOMIC_APPLICATIONS/Codex++.app/user-marker"
printf '%s\n' 'manager-must-be-replaced-with-pair' \
  > "$ATOMIC_APPLICATIONS/Codex++ 管理工具.app/user-marker"
/usr/libexec/PlistBuddy -c 'Delete :CodexKitCompatibilityRevision' \
  "$ATOMIC_APPLICATIONS/Codex++ 管理工具.app/Contents/Info.plist"
atomic_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$ATOMIC_APPLICATIONS" \
  run_core_for_home "$ATOMIC_HOME" install --request-stdin 2>&1)"
[[ ! -e "$ATOMIC_APPLICATIONS/Codex++.app/user-marker" ]] \
  || fail 'Codex++ launcher was not atomically replaced with an unpatched manager'
[[ ! -e "$ATOMIC_APPLICATIONS/Codex++ 管理工具.app/user-marker" ]] \
  || fail 'unpatched Codex++ manager was not replaced'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexKitCompatibilityRevision' \
  "$ATOMIC_APPLICATIONS/Codex++.app/Contents/Info.plist")" == 'cross-provider-content-v1' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexKitCompatibilityRevision' \
  "$ATOMIC_APPLICATIONS/Codex++ 管理工具.app/Contents/Info.plist")" == 'cross-provider-content-v1' ]]
[[ "$(printf '%s' "$atomic_output" | rg -cF '"kind":"installed_app"')" -eq 2 ]] \
  || fail 'Codex++ compatibility upgrade did not replace the app pair'

REUSE_HOME="$OUT/reuse-home"
REUSE_APPLICATIONS="$OUT/reuse-Applications"
prepare_home "$REUSE_HOME"
mkdir -p "$REUSE_APPLICATIONS"
/usr/bin/ditto \
  "$PAYLOAD_ROOT/apps/arm64/ChatGPT.app" \
  "$REUSE_APPLICATIONS/ChatGPT.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 25.1-existing' \
  "$REUSE_APPLICATIONS/ChatGPT.app/Contents/Info.plist"
printf '%s\n' 'preserve-existing-codex' > "$REUSE_APPLICATIONS/ChatGPT.app/user-marker"
reuse_preflight="$(APPLICATIONS_DIR_OVERRIDE="$REUSE_APPLICATIONS" \
  run_core_for_home "$REUSE_HOME" preflight)"
[[ "$reuse_preflight" == *'"installedApplications":{"ChatGPT/Codex":"25.1-existing"}'* ]]
reuse_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$REUSE_APPLICATIONS" \
  run_core_for_home "$REUSE_HOME" install --request-stdin 2>&1)"
[[ "$reuse_output" == *'"kind":"existing_codex_detected"'* ]]
[[ "$reuse_output" == *'"kind":"reused_app"'* ]]
[[ "$reuse_output" == *'未执行覆盖或重复安装'* ]]
[[ "$(< "$REUSE_APPLICATIONS/ChatGPT.app/user-marker")" == 'preserve-existing-codex' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$REUSE_APPLICATIONS/ChatGPT.app/Contents/Info.plist")" == '25.1-existing' ]]
reuse_verify="$(APPLICATIONS_DIR_OVERRIDE="$REUSE_APPLICATIONS" \
  run_core_for_home "$REUSE_HOME" verify 2>&1)"
[[ "$reuse_verify" == *'"kind":"verify_completed"'* ]]
[[ "$reuse_verify" == *'"name":"ChatGPT/Codex","version":"25.1-existing"'* ]]

X86_HOME="$OUT/x86-home"
prepare_home "$X86_HOME"
x86_output="$(printf '%s' "$request" | REAL_ARCH_OVERRIDE=x86_64 run_core_for_home "$X86_HOME" install --request-stdin 2>&1)"
[[ "$x86_output" == *'install_completed'* ]]
[[ "$(< "$APPLICATIONS_DIR/ChatGPT.app/Contents/test-architecture")" == 'x86_64' ]]
[[ "$(< "$APPLICATIONS_DIR/Codex++.app/Contents/test-architecture")" == 'x86_64' ]]

latest_complete_backup="$(find "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups" \
  -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/complete' ';' -print | sort | tail -n 1)"
mkdir -p \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/.pending-zzzz/configuration" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzz-incomplete/configuration" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzx-symlink-marker/configuration"
cp "$latest_complete_backup/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/.pending-zzzz/inventory.json"
cp "$latest_complete_backup/configuration/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/.pending-zzzz/configuration/inventory.json"
: > "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/.pending-zzzz/complete"
cp "$latest_complete_backup/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzz-incomplete/inventory.json"
cp "$latest_complete_backup/configuration/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzz-incomplete/configuration/inventory.json"
cp "$latest_complete_backup/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzx-symlink-marker/inventory.json"
cp "$latest_complete_backup/configuration/inventory.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzx-symlink-marker/configuration/inventory.json"
ln -s /dev/null \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzx-symlink-marker/complete"

printf '%s\n' 'corrupted = true' > "$SUCCESS_HOME/.codex/config.toml"
printf '%s\n' '{"corrupted":true}' > "$SUCCESS_HOME/.codex/auth.json"
printf '%s\n' '{"corrupted":true}' > "$SUCCESS_HOME/.codex-session-delete/settings.json"
printf '%s\n' '{"corrupted":true}' > "$SUCCESS_HOME/.config/Codex++/user_scripts.json"
managed_index=0
for managed_directory in "${managed_directories[@]}"; do
  managed_index=$((managed_index + 1))
  rm -R "$managed_directory"
  mkdir -p "$managed_directory"
  printf 'mutated-managed-%s\n' "$managed_index" > "$managed_directory/mutated-marker"
done
printf '%s\n' 'mutated-translation' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"
printf '%s\n' 'mutated-meter' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-context-used-meter.js"
printf '%s\n' 'installer-created-after-snapshot' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-another-script.js"
printf '%s\n' 'mutated-fourth-payload-script' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-fourth-payload-script.js"
printf '%s\n' 'mutated-custom-market-script' \
  > "$SUCCESS_HOME/.config/Codex++/user_scripts/market-custom.js"
printf '%s\n' 'unrelated-script-after-snapshot' > "$SUCCESS_HOME/.config/Codex++/user_scripts/manual.js"
printf '%s\n' 'unrelated-plugin-after-snapshot' > "$SUCCESS_HOME/.codex/plugins/cache/user-market/custom-plugin/marker"

restore_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" run_core_for_home "$SUCCESS_HOME" restore-latest 2>&1)"
[[ "$restore_output" == *'restore_completed'* ]]
cmp "$OUT/success-original-config.toml" "$SUCCESS_HOME/.codex/config.toml"
cmp "$OUT/success-original-auth.json" "$SUCCESS_HOME/.codex/auth.json"
cmp "$OUT/success-original-settings.json" "$SUCCESS_HOME/.codex-session-delete/settings.json"
cmp "$OUT/success-original-user-scripts.json" "$SUCCESS_HOME/.config/Codex++/user_scripts.json"
cmp "$OUT/success-original-install-expectation.json" \
  "$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json"
managed_index=0
for managed_directory in "${managed_directories[@]}"; do
  managed_index=$((managed_index + 1))
  [[ "$(< "$managed_directory/original-marker")" == "original-managed-$managed_index" ]]
  [[ ! -e "$managed_directory/mutated-marker" ]]
done
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js")" == 'original-translation' ]]
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-context-used-meter.js")" == 'original-meter' ]]
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/market-codex-token-usage.js")" == 'original-token-usage' ]]
[[ "$(jq -r '.scripts["user:market-codex-token-usage.js"]' "$SUCCESS_HOME/.config/Codex++/user_scripts.json")" == false ]]
[[ ! -e "$SUCCESS_HOME/.config/Codex++/user_scripts/market-another-script.js" ]]
[[ ! -e "$SUCCESS_HOME/.config/Codex++/user_scripts/market-fourth-payload-script.js" ]] || \
  fail 'restore left behind a script that was absent before installation'
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/market-custom.js")" == 'original-custom-market-script' ]] || \
  fail 'restore did not recover a pre-existing custom market script'
[[ "$(< "$SUCCESS_HOME/.config/Codex++/user_scripts/manual.js")" == 'unrelated-script-after-snapshot' ]]
[[ "$(< "$SUCCESS_HOME/.codex/plugins/cache/user-market/custom-plugin/marker")" == 'unrelated-plugin-after-snapshot' ]]

MALICIOUS_BACKUP="$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzy-malicious"
/usr/bin/ditto "$latest_complete_backup" "$MALICIOUS_BACKUP"
jq '(.entries[0].backupRelativePath) = "../../outside"' \
  "$MALICIOUS_BACKUP/inventory.json" > "$MALICIOUS_BACKUP/inventory.tmp"
mv "$MALICIOUS_BACKUP/inventory.tmp" "$MALICIOUS_BACKUP/inventory.json"
printf '%s\n' 'must-survive-invalid-inventory' > "$SUCCESS_HOME/.codex/config.toml"
cp "$SUCCESS_APPLICATIONS/ChatGPT.app/original-marker" "$OUT/invalid-inventory-app-before"
set +e
malicious_restore_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" restore-latest 2>&1)"
malicious_restore_status=$?
set -e
[[ "$malicious_restore_status" -eq 67 ]]
[[ "$malicious_restore_output" == *'restore_failed'* ]]
[[ "$(< "$SUCCESS_HOME/.codex/config.toml")" == 'must-survive-invalid-inventory' ]]
cmp "$OUT/invalid-inventory-app-before" "$SUCCESS_APPLICATIONS/ChatGPT.app/original-marker"
rm -R "$MALICIOUS_BACKUP"

UNKNOWN_KEY_BACKUP="$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzy-unknown-key"
/usr/bin/ditto "$latest_complete_backup" "$UNKNOWN_KEY_BACKUP"
jq '(.entries[0].key) = "app.attacker-controlled"' \
  "$UNKNOWN_KEY_BACKUP/inventory.json" > "$UNKNOWN_KEY_BACKUP/inventory.tmp"
mv "$UNKNOWN_KEY_BACKUP/inventory.tmp" "$UNKNOWN_KEY_BACKUP/inventory.json"
set +e
unknown_key_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" restore-latest 2>&1)"
unknown_key_status=$?
set -e
[[ "$unknown_key_status" -eq 67 ]]
[[ "$unknown_key_output" == *'restore_failed'* ]]
[[ "$(< "$SUCCESS_HOME/.codex/config.toml")" == 'must-survive-invalid-inventory' ]]
cmp "$OUT/invalid-inventory-app-before" "$SUCCESS_APPLICATIONS/ChatGPT.app/original-marker"
rm -R "$UNKNOWN_KEY_BACKUP"

INVALID_KIND_BACKUP="$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzy-invalid-kind"
/usr/bin/ditto "$latest_complete_backup" "$INVALID_KIND_BACKUP"
jq '(.entries[] | select(.key == "app.chatgpt") | .kind) = "file"' \
  "$INVALID_KIND_BACKUP/inventory.json" > "$INVALID_KIND_BACKUP/inventory.tmp"
mv "$INVALID_KIND_BACKUP/inventory.tmp" "$INVALID_KIND_BACKUP/inventory.json"
set +e
invalid_kind_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" restore-latest 2>&1)"
invalid_kind_status=$?
set -e
[[ "$invalid_kind_status" -eq 67 ]]
[[ "$invalid_kind_output" == *'restore_failed'* ]]
[[ "$(< "$SUCCESS_HOME/.codex/config.toml")" == 'must-survive-invalid-inventory' ]]
cmp "$OUT/invalid-inventory-app-before" "$SUCCESS_APPLICATIONS/ChatGPT.app/original-marker"
rm -R "$INVALID_KIND_BACKUP"

INVALID_SOURCE_BACKUP="$SUCCESS_HOME/Library/Application Support/Codex One Click Installer/backups/zzzy-invalid-source"
/usr/bin/ditto "$latest_complete_backup" "$INVALID_SOURCE_BACKUP"
invalid_source_relative="$(jq -r '.entries[] | select(.key == "plugin.openai-bundled.browser") | .backupRelativePath' \
  "$INVALID_SOURCE_BACKUP/inventory.json")"
rm -R "$INVALID_SOURCE_BACKUP/$invalid_source_relative"
printf '%s\n' 'wrong-source-kind' > "$INVALID_SOURCE_BACKUP/$invalid_source_relative"
set +e
invalid_source_output="$(APPLICATIONS_DIR_OVERRIDE="$SUCCESS_APPLICATIONS" \
  run_core_for_home "$SUCCESS_HOME" restore-latest 2>&1)"
invalid_source_status=$?
set -e
[[ "$invalid_source_status" -eq 67 ]]
[[ "$invalid_source_output" == *'restore_failed'* ]]
[[ "$(< "$SUCCESS_HOME/.codex/config.toml")" == 'must-survive-invalid-inventory' ]]
cmp "$OUT/invalid-inventory-app-before" "$SUCCESS_APPLICATIONS/ChatGPT.app/original-marker"
rm -R "$INVALID_SOURCE_BACKUP"

RESTORE_SIGNAL_HOME="$OUT/restore-signal-home"
RESTORE_SIGNAL_APPLICATIONS="$OUT/restore-signal-Applications"
prepare_home "$RESTORE_SIGNAL_HOME"
mkdir -p "$RESTORE_SIGNAL_APPLICATIONS"
printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$RESTORE_SIGNAL_APPLICATIONS" \
  run_core_for_home "$RESTORE_SIGNAL_HOME" install --request-stdin >/dev/null 2>&1
printf '%s\n' 'signal-current-app' \
  > "$RESTORE_SIGNAL_APPLICATIONS/ChatGPT.app/Contents/test-architecture"
printf '%s\n' 'signal-current-config' > "$RESTORE_SIGNAL_HOME/.codex/config.toml"
printf '%s\n' 'signal-current-script' \
  > "$RESTORE_SIGNAL_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"
printf '%s\n' 'signal-current-expectation' \
  > "$RESTORE_SIGNAL_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json"
restore_pause_file="$OUT/pause-during-restore"
recovery_pause_file="$OUT/pause-during-restore-recovery"
: > "$restore_pause_file"
: > "$recovery_pause_file"
APPLICATIONS_DIR_OVERRIDE="$RESTORE_SIGNAL_APPLICATIONS" \
TEST_MODE=1 \
HOME="$RESTORE_SIGNAL_HOME" \
APPLICATIONS_DIR="$RESTORE_SIGNAL_APPLICATIONS" \
PAYLOAD_ROOT="$PAYLOAD_ROOT" \
REPORT_DIR="$REPORT_DIR" \
SUPPORT_TOOL="$OUT/installer-support" \
NO_JQ_MARKER="$NO_JQ_MARKER" \
PATH="$NO_JQ_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
REAL_ARCH_OVERRIDE=arm64 \
MACOS_VERSION_OVERRIDE=14.6 \
DISK_BYTES_OVERRIDE=10000000000 \
TEST_PAUSE_RESTORE_FILE="$restore_pause_file" \
TEST_PAUSE_RECOVERY_FILE="$recovery_pause_file" \
bash "$ROOT/Resources/installer-core.sh" restore-latest \
  > "$OUT/restore-signal-output.log" 2>&1 &
restore_signal_pid=$!
for _ in {1..100}; do
  rg -q 'paused_restore' "$OUT/restore-signal-output.log" 2>/dev/null && break
  sleep 0.05
done
rg -q 'paused_restore' "$OUT/restore-signal-output.log" || {
  printf '%s\n' 'installer-transaction-tests: FAIL: restore never reached the injected interruption point' >&2
  exit 1
}
kill -TERM "$restore_signal_pid"
for _ in {1..100}; do
  rg -q 'paused_recovery' "$OUT/restore-signal-output.log" 2>/dev/null && break
  sleep 0.05
done
rg -q 'paused_recovery' "$OUT/restore-signal-output.log" || \
  fail 'rollback never reached the injected repeated-signal window'
kill -TERM "$restore_signal_pid"
rm "$recovery_pause_file" "$restore_pause_file"
set +e
wait "$restore_signal_pid"
restore_signal_status=$?
set -e
[[ "$restore_signal_status" -ne 0 ]]
rg -q 'rollback_completed' "$OUT/restore-signal-output.log"
[[ "$(< "$RESTORE_SIGNAL_APPLICATIONS/ChatGPT.app/Contents/test-architecture")" == 'signal-current-app' ]]
[[ "$(< "$RESTORE_SIGNAL_HOME/.codex/config.toml")" == 'signal-current-config' ]]
[[ "$(< "$RESTORE_SIGNAL_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js")" == 'signal-current-script' ]]
[[ "$(< "$RESTORE_SIGNAL_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json")" == 'signal-current-expectation' ]]
[[ ! -e "$NO_JQ_MARKER" ]] || fail 'installer invoked jq at runtime'

FAIL_APPLICATIONS_DIR="$OUT/failure-Applications"
mkdir -p "$FAIL_APPLICATIONS_DIR/ChatGPT.app" "$FAIL_APPLICATIONS_DIR/Codex++.app" "$FAIL_APPLICATIONS_DIR/Codex++ 管理工具.app"
printf '%s\n' old-chatgpt > "$FAIL_APPLICATIONS_DIR/ChatGPT.app/old-marker"
printf '%s\n' old-launcher > "$FAIL_APPLICATIONS_DIR/Codex++.app/old-marker"
printf '%s\n' old-manager > "$FAIL_APPLICATIONS_DIR/Codex++ 管理工具.app/old-marker"
APP_FAILURE_HOME="$OUT/app-failure-home"
prepare_home "$APP_FAILURE_HOME"
set +e
app_failure_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$FAIL_APPLICATIONS_DIR" FAIL_AFTER_APP_INDEX=2 run_core_for_home "$APP_FAILURE_HOME" install --request-stdin 2>&1)"
app_failure_status=$?
set -e
[[ "$app_failure_status" -ne 0 ]]
[[ "$app_failure_output" == *'rollback_completed'* ]]
[[ -f "$FAIL_APPLICATIONS_DIR/ChatGPT.app/old-marker" ]]
[[ -f "$FAIL_APPLICATIONS_DIR/Codex++.app/old-marker" ]]
[[ -f "$FAIL_APPLICATIONS_DIR/Codex++ 管理工具.app/old-marker" ]]

SCRIPT_FAILURE_HOME="$OUT/script-failure-home"
SCRIPT_FAILURE_APPLICATIONS="$OUT/script-failure-Applications"
prepare_home "$SCRIPT_FAILURE_HOME"
mkdir -p "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts" "$SCRIPT_FAILURE_APPLICATIONS"
printf '%s\n' '{"enabled":false,"scripts":{"user:manual.js":false},"private":true}' > "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts.json"
printf '%s\n' 'old-translation' > "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"
cp "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts.json" "$OUT/script-failure-original-config.json"
cp "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js" "$OUT/script-failure-original.js"
set +e
script_failure_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$SCRIPT_FAILURE_APPLICATIONS" FAIL_AFTER_SCRIPTS=1 run_core_for_home "$SCRIPT_FAILURE_HOME" install --request-stdin 2>&1)"
script_failure_status=$?
set -e
[[ "$script_failure_status" -ne 0 ]]
[[ "$script_failure_output" == *'rollback_completed'* ]]
cmp "$OUT/script-failure-original-config.json" "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts.json"
cmp "$OUT/script-failure-original.js" "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"
[[ ! -e "$SCRIPT_FAILURE_HOME/.config/Codex++/user_scripts/market-another-script.js" ]]
[[ ! -e "$SCRIPT_FAILURE_APPLICATIONS/ChatGPT.app" ]]

CORRUPT_PAYLOAD_ROOT="$OUT/corrupt-payloads"
/usr/bin/ditto "$PAYLOAD_ROOT" "$CORRUPT_PAYLOAD_ROOT"
printf '%s\n' 'window.corrupt = true;' > "$CORRUPT_PAYLOAD_ROOT/script-market/scripts/codex-token-usage.js"
CORRUPT_HOME="$OUT/corrupt-home"
CORRUPT_APPLICATIONS="$OUT/corrupt-Applications"
prepare_home "$CORRUPT_HOME"
mkdir -p "$CORRUPT_APPLICATIONS"
cp "$CORRUPT_HOME/.codex/config.toml" "$OUT/corrupt-original-config.toml"
set +e
corrupt_output="$(printf '%s' "$request" | PAYLOAD_ROOT_OVERRIDE="$CORRUPT_PAYLOAD_ROOT" APPLICATIONS_DIR_OVERRIDE="$CORRUPT_APPLICATIONS" run_core_for_home "$CORRUPT_HOME" install --request-stdin 2>&1)"
corrupt_status=$?
set -e
[[ "$corrupt_status" -ne 0 ]]
[[ "$corrupt_output" == *'invalid_script_payload'* ]]
[[ "$corrupt_output" != *'rollback_completed'* ]]
cmp "$OUT/corrupt-original-config.toml" "$CORRUPT_HOME/.codex/config.toml"
[[ ! -e "$CORRUPT_HOME/.config/Codex++/user_scripts.json" ]]
[[ ! -e "$CORRUPT_APPLICATIONS/ChatGPT.app" ]]
[[ ! -e "$CORRUPT_HOME/Library/Application Support/Codex One Click Installer/backups" ]] \
  || fail 'invalid script payload activated the mutation backup'

CANCEL_HOME="$OUT/cancel-home"
prepare_home "$CANCEL_HOME"
cp "$CANCEL_HOME/.codex/config.toml" "$OUT/cancel-original-config.toml"
pause_file="$OUT/pause-after-config"
: > "$pause_file"
printf '%s' "$request" > "$OUT/cancel-request.json"
TEST_MODE=1 \
HOME="$CANCEL_HOME" \
APPLICATIONS_DIR="$APPLICATIONS_DIR" \
PAYLOAD_ROOT="$PAYLOAD_ROOT" \
REPORT_DIR="$REPORT_DIR" \
SUPPORT_TOOL="$OUT/installer-support" \
NO_JQ_MARKER="$NO_JQ_MARKER" \
PATH="$NO_JQ_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
REAL_ARCH_OVERRIDE=arm64 \
MACOS_VERSION_OVERRIDE=14.6 \
DISK_BYTES_OVERRIDE=10000000000 \
TEST_PAUSE_FILE="$pause_file" \
bash "$ROOT/Resources/installer-core.sh" install --request-stdin \
  < "$OUT/cancel-request.json" \
  > "$OUT/cancel-output.log" \
  2>&1 &
cancel_pid=$!
for _ in {1..100}; do
  rg -q 'paused_after_config' "$OUT/cancel-output.log" 2>/dev/null && break
  sleep 0.05
done
kill -TERM "$cancel_pid"
set +e
wait "$cancel_pid"
cancel_status=$?
set -e
[[ "$cancel_status" -ne 0 ]]
rg -q 'rollback_completed' "$OUT/cancel-output.log"
cmp "$OUT/cancel-original-config.toml" "$CANCEL_HOME/.codex/config.toml"
[[ "$(< "$APPLICATIONS_DIR/ChatGPT.app/Contents/test-architecture")" == 'x86_64' ]]
[[ ! -e "$CANCEL_HOME/.config/Codex++/user_scripts.json" ]]

APP_LINK_HOME="$OUT/app-link-home"
APP_LINK_ESCAPE="$OUT/app-link-escape"
APP_LINK_PATH="$OUT/app-link-Applications"
prepare_home "$APP_LINK_HOME"
mkdir -p "$APP_LINK_ESCAPE"
printf '%s\n' sentinel > "$APP_LINK_ESCAPE/sentinel"
cp "$APP_LINK_ESCAPE/sentinel" "$OUT/app-link-sentinel-before"
ln -s "$APP_LINK_ESCAPE" "$APP_LINK_PATH"
set +e
app_link_output="$(printf '%s' "$request" | APPLICATIONS_DIR_OVERRIDE="$APP_LINK_PATH" run_core_for_home "$APP_LINK_HOME" install --request-stdin 2>&1)"
app_link_status=$?
set -e
[[ "$app_link_status" -eq 65 ]]
cmp "$OUT/app-link-sentinel-before" "$APP_LINK_ESCAPE/sentinel"
[[ "$(find "$APP_LINK_ESCAPE" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]

REPORT_LINK_HOME="$OUT/report-link-home"
REPORT_LINK_APPLICATIONS="$OUT/report-link-Applications"
REPORT_LINK_ESCAPE="$OUT/report-link-escape"
REPORT_LINK_PATH="$OUT/report-link-reports"
prepare_home "$REPORT_LINK_HOME"
mkdir -p "$REPORT_LINK_APPLICATIONS" "$REPORT_LINK_ESCAPE"
printf '%s\n' sentinel > "$REPORT_LINK_ESCAPE/sentinel"
cp "$REPORT_LINK_ESCAPE/sentinel" "$OUT/report-link-sentinel-before"
ln -s "$REPORT_LINK_ESCAPE" "$REPORT_LINK_PATH"
set +e
report_link_output="$(printf '%s' "$request" | \
  APPLICATIONS_DIR_OVERRIDE="$REPORT_LINK_APPLICATIONS" \
  REPORT_DIR_OVERRIDE="$REPORT_LINK_PATH" \
  run_core_for_home "$REPORT_LINK_HOME" install --request-stdin 2>&1)"
report_link_status=$?
set -e
[[ "$report_link_status" -eq 65 ]]
cmp "$OUT/report-link-sentinel-before" "$REPORT_LINK_ESCAPE/sentinel"
[[ "$(find "$REPORT_LINK_ESCAPE" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]
[[ ! -e "$NO_JQ_MARKER" ]] || fail 'installer invoked jq at runtime'

printf '%s\n' 'installer-transaction-tests: PASS'
