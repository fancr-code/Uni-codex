#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(mktemp -d "$TEST_TMPDIR/codex-script-market-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc \
  "$ROOT/Sources/ManagedPathPolicy.swift" \
  "$ROOT/Sources/ScriptMarketInstaller.swift" \
  "$ROOT/tests/script-market-tests.swift" \
  -o "$OUT/script-market-tests"

"$OUT/script-market-tests" "$ROOT/tests/fixtures/script-market"

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

mkdir -p "$OUT/cli-home/user-scripts"
printf '%s\n' '{"enabled":false,"scripts":{"user:manual.js":false},"private":true}' > "$OUT/cli-home/config.json"
result="$("$OUT/installer-support" install-scripts \
  --snapshot "$ROOT/tests/fixtures/script-market" \
  --destination "$OUT/cli-home/user-scripts" \
  --config "$OUT/cli-home/config.json")"
[[ "$result" == *'"installedCount":6'* ]]
[[ "$(jq -r '.scripts["user:market-codex-zhcn-translate.js"]' "$OUT/cli-home/config.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-context-used-meter.js"]' "$OUT/cli-home/config.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-token-usage.js"]' "$OUT/cli-home/config.json")" == true ]]
[[ "$(jq -r '.scripts["user:market-codex-daily-token-usage.js"]' "$OUT/cli-home/config.json")" == false ]]
[[ "$(jq -r '.scripts["user:market-codex-live-token-cost.js"]' "$OUT/cli-home/config.json")" == false ]]
[[ "$(jq -r '.scripts["user:market-another-script.js"]' "$OUT/cli-home/config.json")" == false ]]
[[ "$(jq -r '.private' "$OUT/cli-home/config.json")" == true ]]

SCRIPT_ESCAPE_HOME="$OUT/script-escape-home"
SCRIPT_ESCAPE="$OUT/script-escape"
mkdir -p "$SCRIPT_ESCAPE_HOME/.config" "$SCRIPT_ESCAPE"
printf '%s\n' sentinel > "$SCRIPT_ESCAPE/sentinel"
cp "$SCRIPT_ESCAPE/sentinel" "$OUT/script-sentinel-before"
ln -s "$SCRIPT_ESCAPE" "$SCRIPT_ESCAPE_HOME/.config/Codex++"
set +e
"$OUT/installer-support" install-scripts \
  --snapshot "$ROOT/tests/fixtures/script-market" \
  --destination "$SCRIPT_ESCAPE_HOME/.config/Codex++/user_scripts" \
  --config "$SCRIPT_ESCAPE_HOME/.config/Codex++/user_scripts.json" \
  >/dev/null 2>&1
script_escape_status=$?
set -e
[[ "$script_escape_status" -eq 65 ]]
cmp "$OUT/script-sentinel-before" "$SCRIPT_ESCAPE/sentinel"
[[ "$(find "$SCRIPT_ESCAPE" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]

printf '%s\n' 'script-market-cli-tests: PASS'
