#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codex-provider-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc \
  "$ROOT/Sources/InstallerDomain.swift" \
  "$ROOT/Sources/ProviderCatalog.swift" \
  "$ROOT/tests/provider-catalog-tests.swift" \
  -o "$OUT/provider-catalog-tests"

"$OUT/provider-catalog-tests" "$ROOT/Resources/model-catalog.json"

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

cp "$ROOT/Resources/model-catalog.json" "$OUT/model-catalog.json"
cat > "$OUT/models-response.json" <<'JSON'
{"data":[{"id":"live-b"},{"id":"live-a"},{"id":"live-a"}]}
JSON

secret='sk-provider-cli-secret'
result="$(printf '%s' "$secret" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/models-response.json" "$OUT/installer-support" refresh-models --provider deepseek --catalog "$OUT/model-catalog.json" --key-stdin)"
[[ "$result" == *'"provider":"deepseek"'* ]]
[[ "$result" == *'"count":2'* ]]
[[ "$result" != *"$secret"* ]]
[[ "$(jq -r '.providers[] | select(.kind == "deepseek") | [.models[].id] | join(",")' "$OUT/model-catalog.json")" == 'live-a,live-b' ]]

cp "$OUT/model-catalog.json" "$OUT/before-invalid.json"
printf '%s' '{"wrong":[]}' > "$OUT/models-response.json"
set +e
invalid_output="$(printf '%s' "$secret" | TEST_MODE=1 MODELS_RESPONSE_FILE="$OUT/models-response.json" "$OUT/installer-support" refresh-models --provider deepseek --catalog "$OUT/model-catalog.json" --key-stdin 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" -eq 65 ]]
[[ "$invalid_output" != *"$secret"* ]]
cmp "$OUT/before-invalid.json" "$OUT/model-catalog.json"

fresh_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq --arg generatedAt "$fresh_timestamp" '.generatedAt = $generatedAt' "$ROOT/Resources/model-catalog.json" > "$OUT/fresh-catalog.json"
fresh_result="$("$OUT/installer-support" model-catalog-validate --catalog "$OUT/fresh-catalog.json" --max-age-days 30)"
[[ "$fresh_result" == *'"status":"valid"'* ]]
jq '.generatedAt = "2000-01-01T00:00:00Z"' "$ROOT/Resources/model-catalog.json" > "$OUT/stale-catalog.json"
set +e
stale_output="$("$OUT/installer-support" model-catalog-validate --catalog "$OUT/stale-catalog.json" --max-age-days 30 2>&1)"
stale_status=$?
set -e
[[ "$stale_status" -eq 65 ]]
[[ "$stale_output" == *'stale'* ]]

printf '%s\n' 'provider-catalog-cli-tests: PASS'
