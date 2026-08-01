#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(mktemp -d "$TEST_TMPDIR/codex-plugin-package-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

fail() {
  printf 'plugin-package-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

jq -e '
  .schemaVersion == 1 and
  (.plugins == [
    {"marketplace":"openai-bundled","id":"browser"},
    {"marketplace":"openai-bundled","id":"chrome"},
    {"marketplace":"openai-bundled","id":"computer-use"},
    {"marketplace":"openai-bundled","id":"latex"},
    {"marketplace":"openai-primary-runtime","id":"pdf"},
    {"marketplace":"openai-primary-runtime","id":"documents"},
    {"marketplace":"openai-primary-runtime","id":"spreadsheets"},
    {"marketplace":"openai-primary-runtime","id":"presentations"},
    {"marketplace":"openai-curated","id":"github"}
  ])
' "$ROOT/Resources/plugin-catalog.json" >/dev/null

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
HOME_DIR="$OUT/home"
REPORT_DIR="$OUT/reports"
mkdir -p "$PAYLOAD_ROOT/plugins/marketplaces" "$PAYLOAD_ROOT/plugins/cache" \
  "$APPLICATIONS_DIR" "$HOME_DIR/.codex" "$HOME_DIR/.codex-session-delete" "$REPORT_DIR"
cp "$ROOT/tests/fixtures/payload-manifest.test.json" "$PAYLOAD_ROOT/payload-manifest.json"
cp "$ROOT/Resources/model-catalog.json" "$PAYLOAD_ROOT/model-catalog.json"
cp "$ROOT/Resources/plugin-catalog.json" "$PAYLOAD_ROOT/plugin-catalog.json"
/usr/bin/ditto "$ROOT/tests/fixtures/apps" "$PAYLOAD_ROOT/apps"

printf '%s\n' 'custom_setting = "keep"' '' '[plugins."private@private-market"]' 'enabled = true' > "$HOME_DIR/.codex/config.toml"
printf '%s\n' '{}' > "$HOME_DIR/.codex/auth.json"
printf '%s\n' '{"relayProfiles":[]}' > "$HOME_DIR/.codex-session-delete/settings.json"

marketplace_plugins() {
  case "$1" in
    openai-bundled) printf '%s\n' browser chrome computer-use latex ;;
    openai-primary-runtime) printf '%s\n' pdf documents spreadsheets presentations ;;
    openai-curated) printf '%s\n' github ;;
    *) return 1 ;;
  esac
}

for marketplace in openai-bundled openai-primary-runtime openai-curated; do
  marketplace_root="$PAYLOAD_ROOT/plugins/marketplaces/$marketplace"
  mkdir -p "$marketplace_root/.agents/plugins"
  printf '{"name":"%s","plugins":[]}\n' "$marketplace" > "$marketplace_root/.agents/plugins/marketplace.json"
  while IFS= read -r plugin; do
    plugin_root="$PAYLOAD_ROOT/plugins/cache/$marketplace/$plugin/1.0.0"
    mkdir -p "$plugin_root/.codex-plugin"
    printf '{"name":"%s","version":"1.0.0"}\n' "$plugin" > "$plugin_root/.codex-plugin/plugin.json"
    printf '# %s fixture\n' "$plugin" > "$plugin_root/README.md"
  done < <(marketplace_plugins "$marketplace")
done

(
  cd "$PAYLOAD_ROOT/plugins"
  find marketplaces cache -type f -print | LC_ALL=C sort | while IFS= read -r relative; do
    digest="$(shasum -a 256 "$relative" | awk '{print tolower($1)}')"
    jq -cn --arg path "$relative" --arg sha256 "$digest" '{path:$path,sha256:$sha256}'
  done | jq -s '{schemaVersion:1,files:.}' > file-manifest.json
)

request='{"provider":"deepseek","apiKey":"sk-plugin-test-key","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"]}'
output="$(
  printf '%s' "$request" | \
    TEST_MODE=1 \
    HOME="$HOME_DIR" \
    APPLICATIONS_DIR="$APPLICATIONS_DIR" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$REPORT_DIR" \
    SUPPORT_TOOL="$OUT/installer-support" \
    REAL_ARCH_OVERRIDE=arm64 \
    MACOS_VERSION_OVERRIDE=14.6 \
    DISK_BYTES_OVERRIDE=10000000000 \
    bash "$ROOT/Resources/installer-core.sh" install --request-stdin 2>&1
)"
[[ "$output" == *'install_completed'* ]] || fail 'installer did not complete'

for marketplace in openai-bundled openai-primary-runtime openai-curated; do
  target="$HOME_DIR/.codex/offline-marketplaces/$marketplace"
  [[ -f "$target/.agents/plugins/marketplace.json" ]] || fail "missing marketplace $marketplace"
  rg -Fq "[marketplaces.\"$marketplace\"]" "$HOME_DIR/.codex/config.toml" || fail "marketplace $marketplace not registered"
  rg -q 'source_type = "local"' "$HOME_DIR/.codex/config.toml" || fail 'local marketplace type missing'
done

while IFS=$'\t' read -r marketplace plugin; do
  target="$HOME_DIR/.codex/plugins/cache/$marketplace/$plugin/1.0.0"
  [[ -f "$target/.codex-plugin/plugin.json" ]] || fail "missing plugin $plugin@$marketplace"
  rg -Fq "[plugins.\"$plugin@$marketplace\"]" "$HOME_DIR/.codex/config.toml" || fail "plugin $plugin@$marketplace not enabled"
done < <(jq -r '.plugins[] | [.marketplace,.id] | @tsv' "$ROOT/Resources/plugin-catalog.json")

rg -Fq '[plugins."private@private-market"]' "$HOME_DIR/.codex/config.toml" || fail 'private plugin was not preserved'

assert_plugin_symlink_ancestor_rejected() {
  local label="$1"
  local relative="$2"
  local escape="$OUT/$label-escape"
  local home="$OUT/$label-home"
  local applications="$OUT/$label-Applications"
  local output status
  mkdir -p "$home/.codex" "$home/.codex-session-delete" "$applications" "$escape"
  printf '%s\n' 'model = "before-symlink"' > "$home/.codex/config.toml"
  printf '%s\n' '{}' > "$home/.codex/auth.json"
  printf '%s\n' '{"relayProfiles":[]}' > "$home/.codex-session-delete/settings.json"
  printf '%s\n' sentinel > "$escape/sentinel"
  cp "$escape/sentinel" "$OUT/$label-sentinel-before"
  mkdir -p "$(dirname "$home/$relative")"
  ln -s "$escape" "$home/$relative"
  set +e
  output="$(
    printf '%s' "$request" | \
      TEST_MODE=1 \
      HOME="$home" \
      APPLICATIONS_DIR="$applications" \
      PAYLOAD_ROOT="$PAYLOAD_ROOT" \
      REPORT_DIR="$REPORT_DIR" \
      SUPPORT_TOOL="$OUT/installer-support" \
      REAL_ARCH_OVERRIDE=arm64 \
      MACOS_VERSION_OVERRIDE=14.6 \
      DISK_BYTES_OVERRIDE=10000000000 \
      bash "$ROOT/Resources/installer-core.sh" install --request-stdin 2>&1
  )"
  status=$?
  set -e
  [[ "$status" -eq 65 ]] || fail "$label symlink ancestor was accepted: $output"
  cmp "$OUT/$label-sentinel-before" "$escape/sentinel" || fail "$label sentinel changed"
  [[ "$(find "$escape" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "$label symlink ancestor allowed outside mutation"
}

assert_plugin_symlink_ancestor_rejected marketplace '.codex/offline-marketplaces'
assert_plugin_symlink_ancestor_rejected plugin-cache '.codex/plugins/cache'

ROLLBACK_HOME="$OUT/rollback-home"
ROLLBACK_APPLICATIONS="$OUT/rollback-Applications"
mkdir -p \
  "$ROLLBACK_HOME/.codex/offline-marketplaces/openai-bundled" \
  "$ROLLBACK_HOME/.codex/plugins/cache/openai-bundled/browser/old-version" \
  "$ROLLBACK_HOME/.codex-session-delete" \
  "$ROLLBACK_APPLICATIONS"
printf '%s\n' 'model = "before-plugin-rollback"' 'private_setting = "preserve"' > "$ROLLBACK_HOME/.codex/config.toml"
printf '%s\n' '{}' > "$ROLLBACK_HOME/.codex/auth.json"
printf '%s\n' '{"relayProfiles":[]}' > "$ROLLBACK_HOME/.codex-session-delete/settings.json"
printf '%s\n' 'old-marketplace' > "$ROLLBACK_HOME/.codex/offline-marketplaces/openai-bundled/old-marker"
printf '%s\n' 'old-plugin' > "$ROLLBACK_HOME/.codex/plugins/cache/openai-bundled/browser/old-version/old-marker"
cp "$ROLLBACK_HOME/.codex/config.toml" "$OUT/rollback-original-config.toml"
set +e
rollback_output="$(
  printf '%s' "$request" | \
    TEST_MODE=1 \
    HOME="$ROLLBACK_HOME" \
    APPLICATIONS_DIR="$ROLLBACK_APPLICATIONS" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$REPORT_DIR" \
    SUPPORT_TOOL="$OUT/installer-support" \
    REAL_ARCH_OVERRIDE=arm64 \
    MACOS_VERSION_OVERRIDE=14.6 \
    DISK_BYTES_OVERRIDE=10000000000 \
    FAIL_AFTER_PLUGINS=1 \
    bash "$ROOT/Resources/installer-core.sh" install --request-stdin 2>&1
)"
rollback_status=$?
set -e
[[ "$rollback_status" -ne 0 ]] || fail 'injected plugin failure was accepted'
[[ "$rollback_output" == *'rollback_completed'* ]] || fail 'plugin rollback did not complete'
[[ -f "$ROLLBACK_HOME/.codex/offline-marketplaces/openai-bundled/old-marker" ]] || fail 'marketplace backup was not restored'
[[ -f "$ROLLBACK_HOME/.codex/plugins/cache/openai-bundled/browser/old-version/old-marker" ]] || fail 'plugin backup was not restored'
[[ ! -e "$ROLLBACK_HOME/.codex/offline-marketplaces/openai-curated" ]] || fail 'new marketplace survived rollback'
[[ ! -e "$ROLLBACK_HOME/.codex/plugins/cache/openai-curated/github" ]] || fail 'new plugin survived rollback'
cmp "$OUT/rollback-original-config.toml" "$ROLLBACK_HOME/.codex/config.toml" || fail 'configuration backup was not restored'
[[ ! -e "$ROLLBACK_APPLICATIONS/ChatGPT.app" ]] || fail 'application survived plugin rollback'

TAMPER_HOME="$OUT/tamper-home"
TAMPER_APPLICATIONS="$OUT/tamper-Applications"
mkdir -p "$TAMPER_HOME/.codex" "$TAMPER_HOME/.codex-session-delete" "$TAMPER_APPLICATIONS"
printf '%s\n' 'model = "before-tamper"' > "$TAMPER_HOME/.codex/config.toml"
printf '%s\n' '{}' > "$TAMPER_HOME/.codex/auth.json"
printf '%s\n' '{"relayProfiles":[]}' > "$TAMPER_HOME/.codex-session-delete/settings.json"
printf '%s\n' 'tampered' >> "$PAYLOAD_ROOT/plugins/cache/openai-bundled/browser/1.0.0/README.md"
set +e
tamper_output="$(
  printf '%s' "$request" | \
    TEST_MODE=1 \
    HOME="$TAMPER_HOME" \
    APPLICATIONS_DIR="$TAMPER_APPLICATIONS" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$REPORT_DIR" \
    SUPPORT_TOOL="$OUT/installer-support" \
    REAL_ARCH_OVERRIDE=arm64 \
    MACOS_VERSION_OVERRIDE=14.6 \
    DISK_BYTES_OVERRIDE=10000000000 \
    bash "$ROOT/Resources/installer-core.sh" install --request-stdin 2>&1
)"
tamper_status=$?
set -e
[[ "$tamper_status" -ne 0 ]] || fail 'tampered plugin payload was accepted'
[[ "$tamper_output" == *'plugin payload hash mismatch'* ]] || fail 'tamper failure reason missing'
[[ ! -e "$TAMPER_HOME/.codex/offline-marketplaces" ]] || fail 'tampered deployment left marketplaces behind'
rg -q 'model = "before-tamper"' "$TAMPER_HOME/.codex/config.toml" || fail 'tampered deployment changed configuration'

printf '%s\n' 'plugin-package-tests: PASS'
