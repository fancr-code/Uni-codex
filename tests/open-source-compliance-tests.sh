#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf '%s\n' "open-source-compliance-tests: FAIL: $1" >&2
  exit 1
}

for file in \
  LICENSE \
  LICENSES/MIT.txt \
  LICENSES/Apache-2.0.txt \
  LICENSES/AGPL-3.0-only.txt \
  THIRD_PARTY_NOTICES.md; do
  [[ -s "$ROOT/$file" ]] || fail "missing required licensing file: $file"
done

rg -F 'MIT License' "$ROOT/LICENSE" >/dev/null \
  || fail 'root license is not MIT'
rg -F 'AGPL-3.0-only' "$ROOT/THIRD_PARTY_NOTICES.md" >/dev/null \
  || fail 'Codex++ AGPL boundary is undocumented'
rg -F 'Apache-2.0' "$ROOT/THIRD_PARTY_NOTICES.md" >/dev/null \
  || fail 'Codex CLI Apache boundary is undocumented'
rg -F 'does not grant permission to redistribute' "$ROOT/THIRD_PARTY_NOTICES.md" >/dev/null \
  || fail 'official Codex application redistribution boundary is undocumented'

[[ ! -e "$ROOT/Resources/script-market-sources/codex-context-used-meter.js" ]] \
  || fail 'unlicensed context meter source must not be mirrored'
[[ ! -e "$ROOT/Resources/script-market-sources/codex-token-usage.js" ]] \
  || fail 'unlicensed token usage source must not be mirrored'
jq -e 'all(.overrides[]; .mode != "managed")' \
  "$ROOT/Resources/script-market-overrides.json" >/dev/null \
  || fail 'public source must not publish managed copies of unlicensed scripts'

workflow="$ROOT/.github/workflows/windows-release.yml"
for value in \
  'redistribution_authorized:' \
  'CODEX_REDISTRIBUTION_AUTHORIZED' \
  'Verify redistribution authorization'; do
  rg -F "$value" "$workflow" >/dev/null \
    || fail "Windows release compliance gate omitted: $value"
done

if rg -F 'Resources/script-market-sources' \
    "$ROOT/.github/workflows/windows-ci.yml" >/dev/null; then
  fail 'public CI must not require unlicensed mirrored script sources'
fi
if git -C "$ROOT" grep -n 'Uni-codex/releases/latest' -- \
    ':(exclude)docs/superpowers/**' \
    ':(exclude)tests/open-source-compliance-tests.sh' >/dev/null; then
  fail 'public guidance still directs users to restricted offline releases'
fi

printf '%s\n' 'open-source-compliance-tests: PASS'
