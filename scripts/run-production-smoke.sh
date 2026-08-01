#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
  printf 'run-production-smoke: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 2 ]] || die "usage: $0 /absolute/path/Codex-一键安装.dmg /absolute/path/smoke.json"
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v node >/dev/null 2>&1 || die 'node is required'
[[ -x /usr/bin/sandbox-exec ]] || die 'sandbox-exec is required'

DMG="$1"
OUTPUT="$2"
[[ "$DMG" == /* && -f "$DMG" && ! -L "$DMG" ]] \
  || die 'DMG must be an absolute regular non-symbolic-link path'
[[ "$OUTPUT" == /* && ! -L "$OUTPUT" ]] \
  || die 'output must be an absolute non-symbolic-link path'
OUTPUT_PARENT="$(cd "$(/usr/bin/dirname "$OUTPUT")" && pwd -P)" \
  || die 'output parent does not exist'
OUTPUT="$OUTPUT_PARENT/$(/usr/bin/basename "$OUTPUT")"
[[ ! -e "$OUTPUT" || -f "$OUTPUT" ]] || die 'output must be a regular file'

REAL_HOME="$HOME"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
SMOKE_ROOT="$(/usr/bin/mktemp -d "$TEMP_ROOT/codex-production-smoke.XXXXXX")"
/bin/chmod 700 "$SMOKE_ROOT"
SMOKE_HOME="$SMOKE_ROOT/home"
SMOKE_OUTPUTS="$SMOKE_ROOT/outputs"
SMOKE_TMP="$SMOKE_ROOT/tmp"
PROFILE="$SMOKE_ROOT/sandbox.sb"
ATTACH_PLIST="$SMOKE_ROOT/attach.plist"
CANDIDATE_ATTACH_PLIST="$SMOKE_ROOT/candidate-attach.plist"
INTERNAL_RESULT="$SMOKE_OUTPUTS/smoke.json"
MOUNT_POINT=''
CANDIDATE_MOUNT_POINT=''

cleanup() {
  if [[ -n "$CANDIDATE_MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$CANDIDATE_MOUNT_POINT" >/dev/null 2>&1 \
      || /usr/bin/hdiutil detach "$CANDIDATE_MOUNT_POINT" -force >/dev/null 2>&1 \
      || true
  fi
  if [[ -n "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
      || /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 \
      || true
  fi
  /bin/rm -R "$SMOKE_ROOT"
}
trap cleanup EXIT

/bin/mkdir -p "$SMOKE_HOME" "$SMOKE_OUTPUTS" "$SMOKE_TMP"

snapshot_target() {
  local target="$1"
  if [[ -L "$target" ]]; then
    printf 'link:%s' "$(/usr/bin/readlink "$target")"
  elif [[ -e "$target" ]]; then
    /usr/bin/stat -f 'present:%HT:%z:%m:%c:%Sp' "$target"
  else
    printf 'missing'
  fi
}

REAL_TARGETS=(
  "$REAL_HOME/.codex/config.toml"
  "$REAL_HOME/.codex/auth.json"
  "$REAL_HOME/.codex/offline-marketplaces"
  "$REAL_HOME/.codex/plugins/cache"
  "$REAL_HOME/.codex-session-delete/settings.json"
  "$REAL_HOME/.config/Codex++/user_scripts"
  "$REAL_HOME/.config/Codex++/user_scripts.json"
  "$REAL_HOME/Library/Application Support/Codex One Click Installer"
  "/Applications/ChatGPT.app"
  "/Applications/Codex++.app"
  "/Applications/Codex++ 管理工具.app"
)
BEFORE_STATE="$SMOKE_ROOT/real-targets.before"
AFTER_STATE="$SMOKE_ROOT/real-targets.after"
for target in "${REAL_TARGETS[@]}"; do
  printf '%s\t%s\n' "$target" "$(snapshot_target "$target")"
done > "$BEFORE_STATE"

bash "$ROOT/scripts/verify-release-artifact.sh" "$DMG" >/dev/null \
  || die 'release artifact verification failed'

/usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$DMG" > "$ATTACH_PLIST" \
  || die 'unable to mount DMG'
index=0
while [[ "$index" -lt 32 ]]; do
  MOUNT_POINT="$(/usr/libexec/PlistBuddy \
    -c "Print :system-entities:$index:mount-point" "$ATTACH_PLIST" 2>/dev/null || true)"
  [[ -n "$MOUNT_POINT" ]] && break
  index=$((index + 1))
done
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die 'unable to resolve DMG mount point'

APP="$MOUNT_POINT/Codex 一键安装.app"
RESOURCES="$APP/Contents/Resources"
HELPER="$RESOURCES/installer-support"
CORE="$RESOURCES/installer-core.sh"
PAYLOADS="$RESOURCES/offline-payloads"
[[ -d "$APP" && -x "$HELPER" && -x "$CORE" \
   && -f "$PAYLOADS/model-catalog.json" \
   && -f "$PAYLOADS/plugin-catalog.json" \
   && -f "$PAYLOADS/script-market/index.json" ]] \
  || die 'mounted installer is incomplete'

escaped_root="$(printf '%s' "$SMOKE_ROOT" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')"
cat > "$PROFILE" <<EOF
(version 1)
(deny default)
(allow process*)
(allow sysctl-read)
(allow file-read*)
(allow file-write* (literal "/dev/null"))
(allow file-write* (subpath "/dev/fd"))
(allow file-write* (subpath "$escaped_root"))
EOF

run_sandbox() {
  /usr/bin/sandbox-exec -f "$PROFILE" \
    /usr/bin/env -i \
      HOME="$SMOKE_HOME" \
      TMPDIR="$SMOKE_TMP/" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="en_US.UTF-8" \
      "$@"
}

PREFLIGHT_JSON="$SMOKE_OUTPUTS/preflight.json"
PREFLIGHT_ERROR="$SMOKE_OUTPUTS/preflight.stderr"
if ! run_sandbox "$CORE" preflight > "$PREFLIGHT_JSON" 2> "$PREFLIGHT_ERROR"; then
  /usr/bin/tail -n 20 "$PREFLIGHT_JSON" "$PREFLIGHT_ERROR" >&2 || true
  die 'production preflight failed in sandbox'
fi
jq -e '
  (.architecture == "arm64" or .architecture == "x86_64") and
  (.macOSVersion | type == "string") and
  (.availableDiskBytes | type == "number")
' "$PREFLIGHT_JSON" >/dev/null || die 'production preflight returned invalid JSON'

REQUEST="$SMOKE_OUTPUTS/request.json"
run_sandbox /bin/mkdir -p "$SMOKE_HOME/.codex"
printf '%s\n' \
  '{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-smoke-session"},"smokeFixture":true}' \
  > "$SMOKE_HOME/.codex/auth.json"
cat > "$REQUEST" <<'JSON'
{"provider":"deepseek","apiKey":"sk-smoke-offline-validation-only","defaultModel":"deepseek-v4-pro","availableModels":["deepseek-v4-flash","deepseek-v4-pro"],"modelSource":"offlineSnapshot","authenticationMode":"openAIAccountWithAPI"}
JSON

CONFIG_RESULT="$SMOKE_OUTPUTS/config-result.json"
run_sandbox "$HELPER" apply-config \
  --root "$SMOKE_HOME" \
  --catalog "$PAYLOADS/model-catalog.json" \
  < "$REQUEST" > "$CONFIG_RESULT" \
  || die 'production configuration smoke failed'

run_sandbox /bin/mkdir -p \
  "$SMOKE_HOME/.codex/offline-marketplaces" \
  "$SMOKE_HOME/.codex/plugins/cache" \
  "$SMOKE_HOME/.config/Codex++"
run_sandbox /usr/bin/ditto \
  "$PAYLOADS/plugins/marketplaces" \
  "$SMOKE_HOME/.codex/offline-marketplaces"
run_sandbox /usr/bin/ditto \
  "$PAYLOADS/plugins/cache" \
  "$SMOKE_HOME/.codex/plugins/cache"

PLUGIN_RESULT="$SMOKE_OUTPUTS/plugin-result.json"
run_sandbox "$HELPER" configure-plugins \
  --root "$SMOKE_HOME" \
  --catalog "$PAYLOADS/plugin-catalog.json" \
  > "$PLUGIN_RESULT" || die 'production plugin configuration smoke failed'

SCRIPT_RESULT="$SMOKE_OUTPUTS/script-result.json"
run_sandbox "$HELPER" install-scripts \
  --snapshot "$PAYLOADS/script-market" \
  --destination "$SMOKE_HOME/.config/Codex++/user_scripts" \
  --config "$SMOKE_HOME/.config/Codex++/user_scripts.json" \
  > "$SCRIPT_RESULT" || die 'production script market smoke failed'

CONFIG_VERIFY="$SMOKE_OUTPUTS/config-verify.json"
run_sandbox "$HELPER" verify-config \
  --root "$SMOKE_HOME" \
  --catalog "$PAYLOADS/model-catalog.json" \
  --expectation "$SMOKE_HOME/Library/Application Support/Codex One Click Installer/install-expectation.json" \
  > "$CONFIG_VERIFY" || die 'configuration semantic verification failed'

AUTH_STATUS="$SMOKE_OUTPUTS/auth-status.json"
run_sandbox "$HELPER" chatgpt-auth-status \
  --root "$SMOKE_HOME" \
  > "$AUTH_STATUS" || die 'OpenAI account status verification failed'

PLUGIN_VERIFY="$SMOKE_OUTPUTS/plugin-verify.json"
run_sandbox "$HELPER" verify-plugin-config \
  --root "$SMOKE_HOME" \
  --catalog "$PAYLOADS/plugin-catalog.json" \
  > "$PLUGIN_VERIFY" || die 'plugin semantic verification failed'

jq -e '
  .enabled == true and
  .scripts["user:market-codex-zhcn-translate.js"] == true and
  .scripts["user:market-codex-context-used-meter.js"] == true
' "$SMOKE_HOME/.config/Codex++/user_scripts.json" >/dev/null \
  || die 'required Codex++ scripts are not enabled'

while IFS=$'\t' read -r identifier expected; do
  script="$SMOKE_HOME/.config/Codex++/user_scripts/market-$identifier.js"
  [[ -f "$script" && ! -L "$script" ]] || die "installed script is missing: $identifier"
  actual="$(/usr/bin/shasum -a 256 "$script" | /usr/bin/awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || die "installed script hash mismatch: $identifier"
done < <(jq -er '.scripts[] | [.id,(.sha256 | ascii_downcase)] | @tsv' \
  "$PAYLOADS/script-market/index.json")

jq -e '
  .status == "pass" and
  .provider == "deepseek" and
  .authenticationMode == "openAIAccountWithAPI"
' "$CONFIG_VERIFY" >/dev/null \
  || die 'configuration verification evidence is invalid'
jq -e '
  .authenticated == true and
  .authenticationMode == "chatgpt" and
  .status == "checked"
' "$AUTH_STATUS" >/dev/null || die 'OpenAI account status evidence is invalid'
jq -e '
  .auth_mode == "chatgpt" and
  .tokens.access_token == "synthetic-smoke-session" and
  .smokeFixture == true and
  (has("OPENAI_API_KEY") | not)
' "$SMOKE_HOME/.codex/auth.json" >/dev/null \
  || die 'recommended mode did not preserve the official account session'
jq -e '.status == "pass" and .marketplaceCount == 3 and .pluginCount == 9' \
  "$PLUGIN_VERIFY" >/dev/null || die 'plugin verification evidence is invalid'
jq -e '.installedCount >= 2' "$SCRIPT_RESULT" >/dev/null \
  || die 'script installation evidence is invalid'

case "$(/usr/bin/uname -m)" in
  arm64) candidate_id='codex-plus-plus-arm64' ;;
  x86_64) candidate_id='codex-plus-plus-x86_64' ;;
  *) die 'host architecture has no Codex++ candidate payload' ;;
esac
CANDIDATE_RELATIVE="$(jq -er --arg id "$candidate_id" \
  '.files[] | select(.id == $id) | .relativePath' "$PAYLOADS/payload-manifest.json")" \
  || die 'Codex++ candidate payload is missing from the mounted installer'
CANDIDATE_DMG="$PAYLOADS/$CANDIDATE_RELATIVE"
[[ -f "$CANDIDATE_DMG" && ! -L "$CANDIDATE_DMG" ]] \
  || die 'Codex++ candidate payload is not a regular file'
/usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$CANDIDATE_DMG" > "$CANDIDATE_ATTACH_PLIST" \
  || die 'unable to mount Codex++ candidate payload'
index=0
while [[ "$index" -lt 32 ]]; do
  CANDIDATE_MOUNT_POINT="$(/usr/libexec/PlistBuddy \
    -c "Print :system-entities:$index:mount-point" "$CANDIDATE_ATTACH_PLIST" 2>/dev/null || true)"
  [[ -n "$CANDIDATE_MOUNT_POINT" ]] && break
  index=$((index + 1))
done
[[ -n "$CANDIDATE_MOUNT_POINT" && -d "$CANDIDATE_MOUNT_POINT/Codex++.app" ]] \
  || die 'unable to resolve Codex++ candidate app'

MONITOR_REPORT="$SMOKE_OUTPUTS/codex-plus-monitor.json"
MONITOR_SCREENSHOT="$SMOKE_OUTPUTS/codex-plus-monitor.png"
node "$ROOT/scripts/run-codex-plus-monitor-smoke.mjs" \
  --app "$CANDIDATE_MOUNT_POINT/Codex++.app" \
  --home "$SMOKE_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT" >/dev/null \
  || die 'Codex++ monitor smoke runner failed'
jq -e '
  .status == "pass" and
  .manualRequired == false and
  .contextMeter.visible == true and
  .tokenUsage.visible == true and
  .contextMeter.version == "101" and
  .tokenUsage.version == "0.1.7" and
  (.contextMeter.before != .contextMeter.after) and
  (.tokenUsage.before != .tokenUsage.after) and
  .restartPersistence.contextMeter == true and
  .restartPersistence.tokenUsage == true
' "$MONITOR_REPORT" >/dev/null || die 'Codex++ monitor components are not visibly healthy'

for target in "${REAL_TARGETS[@]}"; do
  printf '%s\t%s\n' "$target" "$(snapshot_target "$target")"
done > "$AFTER_STATE"
/usr/bin/cmp -s "$BEFORE_STATE" "$AFTER_STATE" \
  || die 'a managed target outside the smoke root changed'

artifact_sha="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print tolower($1)}')"
host_architecture="$(/usr/bin/uname -m)"
translated=false
if [[ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
  translated=true
fi

jq -n \
  --arg artifactSHA256 "$artifact_sha" \
  --arg hostArchitecture "$host_architecture" \
  --argjson translated "$translated" \
  '{
    schemaVersion: 1,
    status: "pass",
    artifactSHA256: $artifactSHA256,
    hostArchitecture: $hostArchitecture,
    translated: $translated,
    checks: ["release","preflight","accountRelayConfig","plugins","scripts","selfCheck","codexPlusMonitor"],
    limitations: [
      "does not replace applications or invoke administrator AppleScript",
      "uses synthetic temporary login metadata and does not contact OpenAI"
    ]
  }' > "$INTERNAL_RESULT"

/bin/cp "$INTERNAL_RESULT" "$OUTPUT"
/bin/chmod 600 "$OUTPUT"
printf '%s\n' "$OUTPUT"
