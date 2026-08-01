#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$ROOT/patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch"
DEFAULT_ARCHIVE="$ROOT/vendor/offline-payloads/sources/CodexPlusPlus-v1.2.43.tar.gz"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-plus-compatibility-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

if [[ -n "${CODEX_PLUS_SOURCE_ARCHIVE:-}" ]]; then
  ARCHIVE="$CODEX_PLUS_SOURCE_ARCHIVE"
elif [[ -f "$DEFAULT_ARCHIVE" ]]; then
  ARCHIVE="$DEFAULT_ARCHIVE"
else
  manifest="$ROOT/vendor/offline-payloads/payload-manifest.json"
  relative="$(
    jq -er '.files[] | select(.id == "codex-plus-plus-source") | .relativePath' "$manifest"
  )"
  ARCHIVE="$ROOT/vendor/offline-payloads/$relative"
fi

[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || {
  printf 'codex-plus-compatibility-tests: source archive missing: %s\n' "$ARCHIVE" >&2
  exit 1
}

tar -xzf "$ARCHIVE" -C "$TEMP_ROOT"
SOURCE_ROOT="$(find "$TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/Cargo.toml" ]] || {
  printf '%s\n' 'codex-plus-compatibility-tests: invalid source archive' >&2
  exit 1
}

if [[ ! -f "$SOURCE_ROOT/CODEXKIT-PATCH.md" && -f "$PATCH_FILE" ]]; then
  patch --batch --fuzz=0 -d "$SOURCE_ROOT" -p1 < "$PATCH_FILE"
fi

cp "$ROOT/tests/fixtures/codex-plus/cross_provider_content.rs" \
  "$SOURCE_ROOT/crates/codex-plus-core/tests/codexkit_cross_provider_content.rs"

cargo test \
  --manifest-path "$SOURCE_ROOT/Cargo.toml" \
  -p codex-plus-core \
  --test codexkit_cross_provider_content

printf '%s\n' 'codex-plus-compatibility-tests: PASS'
