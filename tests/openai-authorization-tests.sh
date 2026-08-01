#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/openai-authorization-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

sources=("$ROOT/tests/openai-authorization-tests.swift")
if [[ -f "$ROOT/Sources/OpenAIAuthorization.swift" ]]; then
  sources=("$ROOT/Sources/OpenAIAuthorization.swift" "${sources[@]}")
fi

xcrun swiftc \
  -parse-as-library \
  -framework Security \
  "${sources[@]}" \
  -o "$OUT/openai-authorization-tests"

"$OUT/openai-authorization-tests"
