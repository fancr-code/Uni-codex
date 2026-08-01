#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codex-domain-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc \
  "$ROOT/Sources/InstallerDomain.swift" \
  "$ROOT/tests/installer-domain-tests.swift" \
  -o "$OUT/installer-domain-tests"

"$OUT/installer-domain-tests"

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

architecture="$(TEST_MODE=1 REAL_ARCH_OVERRIDE=arm64 "$OUT/installer-support" hardware-architecture)"
[[ "$architecture" == *'"architecture":"arm64"'* ]]

cat > "$OUT/payload-manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-21T00:00:00Z",
  "files": [
    {
      "id": "chatgpt-codex",
      "version": "1.0",
      "architecture": "universal",
      "relativePath": "apps/ChatGPT.dmg",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "sourceURL": "https://example.invalid/ChatGPT.dmg",
      "format": "dmg",
      "bundleIdentifier": "com.openai.codex",
      "teamIdentifier": "2DC432GLL2"
    },
    {
      "id": "codex-plus-plus-arm64",
      "version": "1.0",
      "architecture": "arm64",
      "relativePath": "apps/CodexPlusPlus-arm64.dmg",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "sourceURL": "https://example.invalid/CodexPlusPlus-arm64.dmg",
      "format": "dmg",
      "compatibilityRevision": "cross-provider-content-v1",
      "licenseID": "AGPL-3.0-only"
    },
    {
      "id": "codex-plus-plus-x86_64",
      "version": "1.0",
      "architecture": "x86_64",
      "relativePath": "apps/CodexPlusPlus-x86_64.dmg",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "sourceURL": "https://example.invalid/CodexPlusPlus-x64.dmg",
      "format": "dmg",
      "compatibilityRevision": "cross-provider-content-v1",
      "licenseID": "AGPL-3.0-only"
    },
    {
      "id": "plugin-marketplaces",
      "version": "2026-07-21",
      "architecture": "any",
      "relativePath": "plugins",
      "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "sourceURL": "https://example.invalid/plugins",
      "format": "directory"
    },
    {
      "id": "script-market",
      "version": "2026-07-21",
      "architecture": "any",
      "relativePath": "scripts",
      "sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "sourceURL": "https://example.invalid/scripts",
      "format": "directory"
    },
    {
      "id": "codex-plus-plus-source",
      "version": "1.0",
      "architecture": "source",
      "relativePath": "sources/CodexPlusPlus.tar.gz",
      "sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "sourceURL": "https://example.invalid/source.tar.gz",
      "format": "archive",
      "compatibilityRevision": "cross-provider-content-v1",
      "licenseID": "AGPL-3.0-only"
    }
  ]
}
JSON

validation="$("$OUT/installer-support" manifest-validate "$OUT/payload-manifest.json")"
[[ "$validation" == *'"status":"valid"'* ]]
[[ "$validation" == *'"payloadCount":6'* ]]

jq 'del(.files[] | select(.id == "codex-plus-plus-x86_64") | .compatibilityRevision)' \
  "$OUT/payload-manifest.json" > "$OUT/unpatched-payload-manifest.json"
set +e
"$OUT/installer-support" manifest-validate > "$OUT/invalid-arguments.log" 2>&1
invalid_arguments_status=$?
printf '{not-json' | "$OUT/installer-support" manifest-validate /dev/stdin > "$OUT/invalid-data.log" 2>&1
invalid_data_status=$?
"$OUT/installer-support" manifest-validate "$OUT/unpatched-payload-manifest.json" \
  > "$OUT/unpatched-manifest.log" 2>&1
unpatched_manifest_status=$?
set -e

[[ "$invalid_arguments_status" -eq 64 ]]
[[ "$invalid_data_status" -eq 65 ]]
[[ "$unpatched_manifest_status" -eq 65 ]]
rg -Fq 'invalid payload manifest' "$OUT/unpatched-manifest.log"

printf '%s\n' 'installer-support-cli-tests: PASS'
