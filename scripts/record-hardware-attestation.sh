#!/usr/bin/env bash
set -euo pipefail
umask 077

die() {
  printf 'record-hardware-attestation: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 3 ]] \
  || die "usage: $0 /path/Codex-一键安装.dmg /path/smoke.json /path/attestation.json"
command -v jq >/dev/null 2>&1 || die 'jq is required'

DMG="$1"
SMOKE="$2"
OUTPUT="$3"
[[ -f "$DMG" && ! -L "$DMG" ]] || die 'DMG must be a regular non-symbolic-link file'
[[ -f "$SMOKE" && ! -L "$SMOKE" ]] || die 'smoke JSON must be a regular non-symbolic-link file'
[[ ! -L "$OUTPUT" ]] || die 'attestation output must not be a symbolic link'

SYSCTL_BIN=/usr/sbin/sysctl
UNAME_BIN=/usr/bin/uname
if [[ "${TEST_MODE:-0}" == 1 ]]; then
  SYSCTL_BIN="${SYSCTL_BIN_OVERRIDE:-$SYSCTL_BIN}"
  UNAME_BIN="${UNAME_BIN_OVERRIDE:-$UNAME_BIN}"
elif [[ "${SYSCTL_BIN_OVERRIDE+x}" == x || "${UNAME_BIN_OVERRIDE+x}" == x ]]; then
  die 'test overrides require TEST_MODE=1'
fi
[[ -x "$SYSCTL_BIN" && -x "$UNAME_BIN" ]] || die 'hardware inspection tools are unavailable'

artifact_sha="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print tolower($1)}')"
jq -e \
  --arg sha "$artifact_sha" \
  '.schemaVersion == 1 and .status == "pass" and
   .artifactSHA256 == $sha and .translated == false and
   (.hostArchitecture == "arm64" or .hostArchitecture == "x86_64")' \
  "$SMOKE" >/dev/null || die 'smoke JSON does not attest this artifact'

arm64_optional="$("$SYSCTL_BIN" -n hw.optional.arm64 2>/dev/null || printf '0')"
translated_value="$("$SYSCTL_BIN" -in sysctl.proc_translated 2>/dev/null || printf '0')"
process_architecture="$("$UNAME_BIN" -m)"
[[ "$translated_value" == 0 ]] || die 'translated execution cannot produce hardware attestation'

if [[ "$arm64_optional" == 1 ]]; then
  [[ "$process_architecture" == arm64 ]] || die 'Apple Silicon attestation requires native arm64 execution'
  architecture=arm64
else
  [[ "$process_architecture" == x86_64 ]] || die 'Intel attestation requires native x86_64 execution'
  architecture=x86_64
fi
[[ "$(jq -r '.hostArchitecture' "$SMOKE")" == "$architecture" ]] \
  || die 'smoke architecture does not match native hardware'

hardware_model="$("$SYSCTL_BIN" -n hw.model 2>/dev/null)" \
  || die 'unable to read hardware model'
[[ -n "$hardware_model" ]] || die 'hardware model is empty'
recorded_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

temporary="$OUTPUT.tmp.$$"
trap '/bin/rm -f "$temporary"' EXIT
jq -n \
  --arg artifactSHA256 "$artifact_sha" \
  --arg architecture "$architecture" \
  --arg hardwareModel "$hardware_model" \
  --arg recordedAt "$recorded_at" \
  '{
    schemaVersion: 1,
    artifactSHA256: $artifactSHA256,
    architecture: $architecture,
    hardwareModel: $hardwareModel,
    translated: false,
    smokeStatus: "pass",
    recordedAt: $recordedAt
  }' > "$temporary"
/bin/chmod 600 "$temporary"
/bin/mv -f "$temporary" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
