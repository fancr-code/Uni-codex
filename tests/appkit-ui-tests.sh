#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/codex-appkit-ui-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

sed '/^@main$/,$d' "$ROOT/Sources/CodexOneClickInstaller.swift" > "$OUT/CodexOneClickInstaller.swift"

xcrun swiftc \
  -target "$(uname -m)-apple-macos14.0" \
  -framework Cocoa \
  -framework Security \
  "$ROOT/Sources/InstallerDomain.swift" \
  "$ROOT/Sources/ProviderCatalog.swift" \
  "$ROOT/Sources/InstallerState.swift" \
  "$ROOT/Sources/OpenAIAuthorization.swift" \
  "$OUT/CodexOneClickInstaller.swift" \
  "$ROOT/tests/appkit-ui-tests.swift" \
  -o "$OUT/appkit-ui-tests"

mkdir -p "$OUT/home"
HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" "$OUT/appkit-ui-tests"
