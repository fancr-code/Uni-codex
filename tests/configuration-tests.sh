#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(mktemp -d "$TEST_TMPDIR/codex-configuration-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc \
  "$ROOT/Sources/InstallerDomain.swift" \
  "$ROOT/Sources/TomlDocument.swift" \
  "$ROOT/Sources/ManagedPathPolicy.swift" \
  "$ROOT/Sources/InstallerBackup.swift" \
  "$ROOT/Sources/InstallExpectation.swift" \
  "$ROOT/Sources/InstallerConfiguration.swift" \
  "$ROOT/tests/configuration-tests.swift" \
  -o "$OUT/configuration-tests"

"$OUT/configuration-tests"

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

cat > "$OUT/model-catalog.json" <<'JSON'
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-21T00:00:00Z",
  "providers": [
    {
      "kind": "deepseek",
      "protocolName": "chatCompletions",
      "models": [
        {"id":"deepseek-v4-flash","displayName":"DeepSeek V4 Flash","contextWindow":1000000},
        {"id":"deepseek-v4-pro","displayName":"DeepSeek V4 Pro","contextWindow":1000000}
      ]
    },
    {
      "kind": "kimi-open",
      "protocolName": "chatCompletions",
      "models": [
        {"id":"kimi-k2.6","displayName":"Kimi K2.6","contextWindow":1000000}
      ]
    }
  ]
}
JSON

request='{"provider":"deepseek","apiKey":"sk-cli-test-key","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"]}'
mkdir -p \
  "$OUT/home" \
  "$OUT/account-home/.codex" \
  "$OUT/account-login-pending-home" \
  "$OUT/short-home" \
  "$OUT/live-home" \
  "$OUT/offline-live-home" \
  "$OUT/whitespace-frozen-home" \
  "$OUT/legacy-live-home" \
  "$OUT/kimi-home" \
  "$OUT/malformed-provider-home"
result="$(printf '%s' "$request" | "$OUT/installer-support" apply-config --root "$OUT/home" --catalog "$OUT/model-catalog.json")"
[[ "$result" == *'"managedProviderID":"codex-one-click-deepseek"'* ]]
[[ "$result" == *'"modelSource":"offlineSnapshot"'* ]]
[[ "$result" != *'sk-cli-test-key'* ]]
[[ -f "$OUT/home/.codex/config.toml" ]]
[[ -f "$OUT/home/.codex/auth.json" ]]
[[ -f "$OUT/home/.codex-session-delete/settings.json" ]]
EXPECTATION="$OUT/home/Library/Application Support/Codex One Click Installer/install-expectation.json"
[[ -f "$EXPECTATION" ]]
expectation_hash="$(/usr/bin/plutil -extract apiKeySHA256 raw -o - "$EXPECTATION")"
verification="$("$OUT/installer-support" verify-config \
  --root "$OUT/home" \
  --catalog "$OUT/model-catalog.json" \
  --expectation "$EXPECTATION")"
[[ "$verification" == *'"status":"pass"'* ]]
[[ "$verification" == *'"provider":"deepseek"'* ]]
[[ "$verification" == *'"defaultModel":"deepseek-v4-pro"'* ]]
[[ "$verification" != *'sk-cli-test-key'* ]]
[[ "$verification" != *"$expectation_hash"* ]]

account_request='{"provider":"deepseek","apiKey":"sk-account-plus-api-key","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"],"authenticationMode":"openAIAccountWithAPI"}'
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"official-session-token"},"userFlag":true}' \
  > "$OUT/account-home/.codex/auth.json"
account_result="$(printf '%s' "$account_request" | "$OUT/installer-support" apply-config \
  --root "$OUT/account-home" --catalog "$OUT/model-catalog.json")"
[[ "$account_result" == *'"authenticationMode":"openAIAccountWithAPI"'* ]]
[[ "$account_result" != *'sk-account-plus-api-key'* ]]
rg -Fq 'experimental_bearer_token = "sk-account-plus-api-key"' \
  "$OUT/account-home/.codex/config.toml"
jq -e '
  .auth_mode == "chatgpt" and
  .tokens.access_token == "official-session-token" and
  .userFlag == true and
  has("OPENAI_API_KEY") == false
' "$OUT/account-home/.codex/auth.json" >/dev/null
jq -e '
  .relayProfilesEnabled == true and
  ([.relayProfiles[] | select(
    .id == "codex-one-click-deepseek" and
    .relayMode == "official" and
    .officialMixApiKey == true and
    .authContents == "" and
    (.configContents | contains("experimental_bearer_token"))
  )] | length) == 1
' "$OUT/account-home/.codex-session-delete/settings.json" >/dev/null
ACCOUNT_EXPECTATION="$OUT/account-home/Library/Application Support/Codex One Click Installer/install-expectation.json"
[[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$ACCOUNT_EXPECTATION")" == 2 ]]
[[ "$(/usr/bin/plutil -extract authenticationMode raw -o - "$ACCOUNT_EXPECTATION")" == openAIAccountWithAPI ]]
account_verification="$("$OUT/installer-support" verify-config \
  --root "$OUT/account-home" \
  --catalog "$OUT/model-catalog.json" \
  --expectation "$ACCOUNT_EXPECTATION")"
[[ "$account_verification" == *'"authenticationMode":"openAIAccountWithAPI"'* ]]
[[ "$account_verification" == *'"status":"pass"'* ]]
[[ "$account_verification" != *'official-session-token'* ]]
[[ "$account_verification" != *'sk-account-plus-api-key'* ]]

account_auth_status="$("$OUT/installer-support" chatgpt-auth-status --root "$OUT/account-home")"
[[ "$account_auth_status" == '{"authenticated":true,"authenticationMode":"chatgpt","status":"checked"}' ]]
[[ "$account_auth_status" != *'official-session-token'* ]]

pending_result="$(printf '%s' "$account_request" | "$OUT/installer-support" apply-config \
  --root "$OUT/account-login-pending-home" --catalog "$OUT/model-catalog.json")"
[[ "$pending_result" == *'"authenticationMode":"openAIAccountWithAPI"'* ]]
pending_auth_status="$("$OUT/installer-support" chatgpt-auth-status \
  --root "$OUT/account-login-pending-home")"
[[ "$pending_auth_status" == '{"authenticated":false,"authenticationMode":"none","status":"checked"}' ]]
jq -e 'has("OPENAI_API_KEY") == false' \
  "$OUT/account-login-pending-home/.codex/auth.json" >/dev/null

set +e
short_key_output="$(printf '%s' '{"provider":"deepseek","apiKey":"short","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-pro"]}' | "$OUT/installer-support" apply-config --root "$OUT/short-home" --catalog "$OUT/model-catalog.json" 2>&1)"
short_key_status=$?
set -e
[[ "$short_key_status" -eq 65 ]]
[[ "$short_key_output" != *'short'* ]]

cat > "$OUT/live-models.json" <<'JSON'
{"provider":"deepseek","data":[{"id":"live-only"}]}
JSON
cp "$OUT/model-catalog.json" "$OUT/frozen-before-live.json"

live_request='{"provider":"deepseek","apiKey":"sk-live-model-secret","defaultModel":"live-only","availableModels":["live-only"],"modelSource":"upstreamRefresh"}'
live_result="$(printf '%s' "$live_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/live-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/live-home" --catalog "$OUT/model-catalog.json")"
[[ "$live_result" == *'"modelSource":"upstreamRefresh"'* ]]
[[ "$live_result" == *'"modelCount":1'* ]]
[[ "$live_result" != *'sk-live-model-secret'* ]]
rg -Fq 'model = "live-only"' "$OUT/live-home/.codex/config.toml"
cmp "$OUT/frozen-before-live.json" "$OUT/model-catalog.json"

offline_live_request='{"provider":"deepseek","apiKey":"sk-live-model-secret","defaultModel":"live-only","availableModels":["live-only"],"modelSource":"offlineSnapshot"}'
set +e
offline_live_output="$(printf '%s' "$offline_live_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/missing-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/offline-live-home" --catalog "$OUT/model-catalog.json" 2>&1)"
offline_live_status=$?
set -e
[[ "$offline_live_status" -eq 65 ]]
[[ "$offline_live_output" == *'selected model is absent from the offline catalog'* ]]
[[ "$offline_live_output" != *'sk-live-model-secret'* ]]

whitespace_frozen_request='{"provider":"deepseek","apiKey":"sk-frozen-model-secret","defaultModel":" deepseek-v4-pro ","availableModels":[" deepseek-v4-pro ","deepseek-v4-pro","   "],"modelSource":"upstreamRefresh"}'
whitespace_frozen_result="$(printf '%s' "$whitespace_frozen_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/missing-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/whitespace-frozen-home" --catalog "$OUT/model-catalog.json")"
[[ "$whitespace_frozen_result" == *'"modelSource":"offlineSnapshot"'* ]]
[[ "$whitespace_frozen_result" != *'sk-frozen-model-secret'* ]]
rg -Fq 'model = "deepseek-v4-pro"' "$OUT/whitespace-frozen-home/.codex/config.toml"

legacy_live_request='{"provider":"deepseek","apiKey":"sk-live-model-secret","defaultModel":"live-only","availableModels":["live-only"]}'
set +e
legacy_live_output="$(printf '%s' "$legacy_live_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/missing-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/legacy-live-home" --catalog "$OUT/model-catalog.json" 2>&1)"
legacy_live_status=$?
set -e
[[ "$legacy_live_status" -eq 65 ]]
[[ "$legacy_live_output" == *'selected model is absent from the offline catalog'* ]]
[[ "$legacy_live_output" != *'sk-live-model-secret'* ]]

kimi_request='{"provider":"kimi-open","apiKey":"sk-kimi-model-secret","defaultModel":"live-only","availableModels":["live-only"],"modelSource":"upstreamRefresh"}'
set +e
kimi_output="$(printf '%s' "$kimi_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/live-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/kimi-home" --catalog "$OUT/model-catalog.json" 2>&1)"
kimi_status=$?
set -e
[[ "$kimi_status" -eq 65 ]]
[[ "$kimi_output" == *'fixture response is scoped to another provider'* ]]
[[ "$kimi_output" != *'sk-kimi-model-secret'* ]]

cat > "$OUT/malformed-provider-models.json" <<'JSON'
{"provider":"not-a-provider","data":[{"id":"live-only"}]}
JSON
set +e
malformed_provider_output="$(printf '%s' "$live_request" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/malformed-provider-models.json" \
  "$OUT/installer-support" apply-config --root "$OUT/malformed-provider-home" --catalog "$OUT/model-catalog.json" 2>&1)"
malformed_provider_status=$?
set -e
[[ "$malformed_provider_status" -eq 65 ]]
[[ "$malformed_provider_output" == *'invalid fixture provider metadata'* ]]
[[ "$malformed_provider_output" != *'sk-live-model-secret'* ]]

assert_apply_config_rejects_symlink_ancestor() {
  local label="$1"
  local relative="$2"
  local escape="$OUT/$label-escape"
  local home="$OUT/$label-home"
  local link_path="$home/$relative"
  local status
  mkdir -p "$home" "$escape"
  printf '%s\n' sentinel > "$escape/sentinel"
  cp "$escape/sentinel" "$OUT/$label-sentinel-before"
  mkdir -p "$(dirname "$link_path")"
  ln -s "$escape" "$link_path"
  set +e
  printf '%s' "$request" | "$OUT/installer-support" apply-config \
    --root "$home" --catalog "$OUT/model-catalog.json" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 65 ]]
  cmp "$OUT/$label-sentinel-before" "$escape/sentinel"
  [[ "$(find "$escape" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]
}

assert_apply_config_rejects_symlink_ancestor codex '.codex'
assert_apply_config_rejects_symlink_ancestor settings '.codex-session-delete'
assert_apply_config_rejects_symlink_ancestor backup \
  'Library/Application Support/Codex One Click Installer'

ROOT_ESCAPE="$OUT/root-escape"
ROOT_ALIAS="$OUT/root-alias"
mkdir -p "$ROOT_ESCAPE/home"
printf '%s\n' sentinel > "$ROOT_ESCAPE/sentinel"
cp "$ROOT_ESCAPE/sentinel" "$OUT/root-sentinel-before"
ln -s "$ROOT_ESCAPE" "$ROOT_ALIAS"
set +e
printf '%s' "$request" | "$OUT/installer-support" apply-config \
  --root "$ROOT_ALIAS/home" --catalog "$OUT/model-catalog.json" >/dev/null 2>&1
root_escape_status=$?
set -e
[[ "$root_escape_status" -eq 65 ]]
cmp "$OUT/root-sentinel-before" "$ROOT_ESCAPE/sentinel"
[[ "$(find "$ROOT_ESCAPE/home" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 0 ]]

SNAPSHOT_HOME="$OUT/snapshot-home"
SNAPSHOT_ROOT="$SNAPSHOT_HOME/Library/Application Support/Codex One Click Installer/backups"
SNAPSHOT="$SNAPSHOT_ROOT/.pending-test/configuration"
mkdir -p "$SNAPSHOT_HOME/.codex" "$SNAPSHOT_HOME/.codex-session-delete" "$SNAPSHOT_ROOT/.pending-test"
backup_identifier="$("$OUT/installer-support" backup-identifier | jq -r '.identifier')"
[[ "$backup_identifier" =~ ^[0-9]{20}-[0-9a-f-]{36}$ ]]
printf '%s\n' 'model = "snapshot-original"' > "$SNAPSHOT_HOME/.codex/config.toml"
printf '%s\n' '{"OPENAI_API_KEY":"sk-snapshot-secret"}' > "$SNAPSHOT_HOME/.codex/auth.json"
printf '%s\n' '{"snapshot":true}' > "$SNAPSHOT_HOME/.codex-session-delete/settings.json"
cp "$SNAPSHOT_HOME/.codex/config.toml" "$OUT/snapshot-original-config.toml"
cp "$SNAPSHOT_HOME/.codex/auth.json" "$OUT/snapshot-original-auth.json"
cp "$SNAPSHOT_HOME/.codex-session-delete/settings.json" "$OUT/snapshot-original-settings.json"

snapshot_result="$("$OUT/installer-support" snapshot-config --root "$SNAPSHOT_HOME" --backup "$SNAPSHOT")"
[[ "$snapshot_result" == *'"status":"snapshotted"'* ]]
[[ "$(jq -r '.schemaVersion' "$SNAPSHOT/inventory.json")" -eq 2 ]]
[[ "$(jq -r '.entries | length' "$SNAPSHOT/inventory.json")" -eq 3 ]]
[[ "$(jq '[.entries[].key] | unique | length' "$SNAPSHOT/inventory.json")" -eq 3 ]]
! rg -q 'originalPath|sk-snapshot-secret|snapshot-home' "$SNAPSHOT/inventory.json"

printf '%s\n' 'model = "mutated"' > "$SNAPSHOT_HOME/.codex/config.toml"
printf '%s\n' '{"mutated":true}' > "$SNAPSHOT_HOME/.codex/auth.json"
rm "$SNAPSHOT_HOME/.codex-session-delete/settings.json"
"$OUT/installer-support" restore-config --root "$SNAPSHOT_HOME" --backup "$SNAPSHOT" >/dev/null
cmp "$OUT/snapshot-original-config.toml" "$SNAPSHOT_HOME/.codex/config.toml"
cmp "$OUT/snapshot-original-auth.json" "$SNAPSHOT_HOME/.codex/auth.json"
cmp "$OUT/snapshot-original-settings.json" "$SNAPSHOT_HOME/.codex-session-delete/settings.json"

INVALID_SNAPSHOT="$SNAPSHOT_ROOT/.pending-invalid/configuration"
mkdir -p "$(dirname "$INVALID_SNAPSHOT")"
/usr/bin/ditto "$SNAPSHOT" "$INVALID_SNAPSHOT"
auth_relative="$(jq -r '.entries[] | select(.key == "config.codex-auth") | .backupRelativePath' "$INVALID_SNAPSHOT/inventory.json")"
rm "$INVALID_SNAPSHOT/$auth_relative"
mkdir "$INVALID_SNAPSHOT/$auth_relative"
printf '%s\n' 'model = "must-not-change"' > "$SNAPSHOT_HOME/.codex/config.toml"
printf '%s\n' '{"mustNotChange":true}' > "$SNAPSHOT_HOME/.codex/auth.json"
printf '%s\n' '{"mustNotChange":true}' > "$SNAPSHOT_HOME/.codex-session-delete/settings.json"
set +e
invalid_restore_output="$("$OUT/installer-support" restore-config \
  --root "$SNAPSHOT_HOME" --backup "$INVALID_SNAPSHOT" 2>&1)"
invalid_restore_status=$?
set -e
[[ "$invalid_restore_status" -eq 65 ]]
[[ "$invalid_restore_output" == *'invalid backup data'* ]]
[[ "$(< "$SNAPSHOT_HOME/.codex/config.toml")" == 'model = "must-not-change"' ]]
[[ "$(< "$SNAPSHOT_HOME/.codex/auth.json")" == '{"mustNotChange":true}' ]]
[[ "$(< "$SNAPSHOT_HOME/.codex-session-delete/settings.json")" == '{"mustNotChange":true}' ]]

printf '%s\n' 'configuration-cli-tests: PASS'
