#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'verify-hardware-attestations: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 3 ]] \
  || die "usage: $0 /path/Codex-一键安装.dmg /path/arm64.json /path/x86_64.json"
command -v jq >/dev/null 2>&1 || die 'jq is required'

DMG="$1"
FIRST="$2"
SECOND="$3"
[[ -f "$DMG" && ! -L "$DMG" ]] || die 'DMG must be a regular non-symbolic-link file'
for attestation in "$FIRST" "$SECOND"; do
  [[ -f "$attestation" && ! -L "$attestation" ]] \
    || die 'attestations must be regular non-symbolic-link files'
done

artifact_sha="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print tolower($1)}')"
for attestation in "$FIRST" "$SECOND"; do
  jq -e \
    --arg sha "$artifact_sha" \
    '.schemaVersion == 1 and
     .artifactSHA256 == $sha and
     (.architecture == "arm64" or .architecture == "x86_64") and
     (.hardwareModel | type == "string" and length > 0) and
     .translated == false and
     .smokeStatus == "pass" and
     (.recordedAt | type == "string" and length > 0)' \
    "$attestation" >/dev/null || die "invalid attestation: $attestation"
done

first_arch="$(jq -r '.architecture' "$FIRST")"
second_arch="$(jq -r '.architecture' "$SECOND")"
[[ "$first_arch" != "$second_arch" ]] || die 'duplicate hardware architectures'
architectures="$(printf '%s\n%s\n' "$first_arch" "$second_arch" | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "$architectures" == 'arm64 x86_64 ' ]] || die 'both arm64 and x86_64 attestations are required'

jq -n \
  --arg artifactSHA256 "$artifact_sha" \
  '{
    schemaVersion: 1,
    status: "pass",
    artifactSHA256: $artifactSHA256,
    architectures: ["arm64","x86_64"],
    hardwareAttested: true
  }'
