#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(/usr/bin/mktemp -d "$TEST_TMPDIR/codex-production-smoke-tests.XXXXXX")"
trap '/bin/rm -R "$OUT"' EXIT

fail() {
  printf 'production-smoke-tests: FAIL: %s\n' "$*" >&2
  exit 1
}

SMOKE_SCRIPT="$ROOT/scripts/run-production-smoke.sh"
MONITOR_SMOKE_SCRIPT="$ROOT/scripts/run-codex-plus-monitor-smoke.mjs"
NODE_BIN="$(command -v node)"
RECORD_SCRIPT="$ROOT/scripts/record-hardware-attestation.sh"
VERIFY_SCRIPT="$ROOT/scripts/verify-hardware-attestations.sh"
for script in "$SMOKE_SCRIPT" "$RECORD_SCRIPT" "$VERIFY_SCRIPT"; do
  bash -n "$script"
done

DMG="$OUT/Codex-一键安装.dmg"
printf '%s\n' 'fixture artifact' > "$DMG"
sha="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print tolower($1)}')"

write_attestation() {
  local path="$1"
  local architecture="$2"
  local translated="$3"
  local status="$4"
  local digest="${5:-$sha}"
  jq -n \
    --arg sha "$digest" \
    --arg architecture "$architecture" \
    --argjson translated "$translated" \
    --arg status "$status" \
    '{
      schemaVersion:1,
      artifactSHA256:$sha,
      architecture:$architecture,
      hardwareModel:"FixtureMac",
      translated:$translated,
      smokeStatus:$status,
      recordedAt:"2026-07-23T00:00:00Z"
    }' > "$path"
}

ARM="$OUT/arm64.json"
INTEL="$OUT/x86_64.json"
write_attestation "$ARM" arm64 false pass
write_attestation "$INTEL" x86_64 false pass
bash "$VERIFY_SCRIPT" "$DMG" "$ARM" "$INTEL" \
  | jq -e '.hardwareAttested == true and .status == "pass"' >/dev/null

assert_rejected() {
  local label="$1"
  shift
  set +e
  "$@" > "$OUT/$label.out" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$label was accepted"
}

WRONG="$OUT/wrong-sha.json"
write_attestation "$WRONG" x86_64 false pass "$(printf '0%.0s' {1..64})"
assert_rejected wrong-sha bash "$VERIFY_SCRIPT" "$DMG" "$ARM" "$WRONG"
assert_rejected duplicate bash "$VERIFY_SCRIPT" "$DMG" "$ARM" "$ARM"

TRANSLATED="$OUT/translated.json"
write_attestation "$TRANSLATED" x86_64 true pass
assert_rejected translated bash "$VERIFY_SCRIPT" "$DMG" "$ARM" "$TRANSLATED"

FAILED="$OUT/failed.json"
write_attestation "$FAILED" x86_64 false fail
assert_rejected failed-smoke bash "$VERIFY_SCRIPT" "$DMG" "$ARM" "$FAILED"

FAKE_SYSCTL="$OUT/fake-sysctl"
cat > "$FAKE_SYSCTL" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-n hw.optional.arm64') printf '%s\n' "${FAKE_ARM64:-1}" ;;
  '-in sysctl.proc_translated') printf '%s\n' "${FAKE_TRANSLATED:-0}" ;;
  '-n hw.model') printf '%s\n' 'FixtureMac15,1' ;;
  *) exit 1 ;;
esac
SH
FAKE_UNAME="$OUT/fake-uname"
cat > "$FAKE_UNAME" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -m ]] || exit 1
printf '%s\n' "${FAKE_UNAME_ARCH:-arm64}"
SH
/bin/chmod +x "$FAKE_SYSCTL" "$FAKE_UNAME"

SMOKE="$OUT/smoke.json"
jq -n --arg sha "$sha" \
  '{schemaVersion:1,status:"pass",artifactSHA256:$sha,hostArchitecture:"arm64",translated:false}' \
  > "$SMOKE"
RECORDED="$OUT/recorded.json"
TEST_MODE=1 \
SYSCTL_BIN_OVERRIDE="$FAKE_SYSCTL" \
UNAME_BIN_OVERRIDE="$FAKE_UNAME" \
bash "$RECORD_SCRIPT" "$DMG" "$SMOKE" "$RECORDED" >/dev/null
jq -e '.architecture == "arm64" and .translated == false and .smokeStatus == "pass"' \
  "$RECORDED" >/dev/null

assert_rejected translated-record \
  env TEST_MODE=1 FAKE_TRANSLATED=1 \
    SYSCTL_BIN_OVERRIDE="$FAKE_SYSCTL" UNAME_BIN_OVERRIDE="$FAKE_UNAME" \
    bash "$RECORD_SCRIPT" "$DMG" "$SMOKE" "$OUT/rejected.json"

assert_rejected relative-dmg bash "$SMOKE_SCRIPT" \
  Codex-一键安装.dmg "$OUT/output.json"
assert_rejected relative-output bash "$SMOKE_SCRIPT" \
  "$DMG" output.json
ln -s "$DMG" "$OUT/link.dmg"
assert_rejected symlink-dmg bash "$SMOKE_SCRIPT" \
  "$OUT/link.dmg" "$OUT/output.json"

MONITOR_HOME="$OUT/monitor-home"
MONITOR_REPORT="$OUT/monitor-report.json"
MONITOR_SCREENSHOT="$OUT/monitor.png"
FAKE_APP="$OUT/Codex++.app"
/bin/mkdir -p "$FAKE_APP/Contents/MacOS" "$MONITOR_HOME"

write_launcher_fixture() {
  local destination="$1"
  cat > "$destination" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  /bin/chmod 755 "$destination"
}

APP_SYMLINK_TARGET="$OUT/app-symlink-target/Codex++.app"
APP_SYMLINK="$OUT/AppSymlink.app"
/bin/mkdir -p "$APP_SYMLINK_TARGET/Contents/MacOS"
/usr/bin/plutil -create xml1 "$APP_SYMLINK_TARGET/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string 'CodexPlusPlus' \
  "$APP_SYMLINK_TARGET/Contents/Info.plist"
write_launcher_fixture "$APP_SYMLINK_TARGET/Contents/MacOS/CodexPlusPlus"
/bin/ln -s "$APP_SYMLINK_TARGET" "$APP_SYMLINK"
assert_rejected app-symlink node "$MONITOR_SMOKE_SCRIPT" \
  --app "$APP_SYMLINK" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'candidate app is not a regular directory' "$OUT/app-symlink.out" \
  || fail 'app symlink parent chain was not rejected'

CONTENTS_SYMLINK_APP="$OUT/ContentsSymlink.app"
CONTENTS_SYMLINK_TARGET="$OUT/contents-symlink-target"
/bin/mkdir -p "$CONTENTS_SYMLINK_APP" "$CONTENTS_SYMLINK_TARGET/MacOS"
/usr/bin/plutil -create xml1 "$CONTENTS_SYMLINK_TARGET/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string 'CodexPlusPlus' \
  "$CONTENTS_SYMLINK_TARGET/Info.plist"
write_launcher_fixture "$CONTENTS_SYMLINK_TARGET/MacOS/CodexPlusPlus"
/bin/ln -s "$CONTENTS_SYMLINK_TARGET" "$CONTENTS_SYMLINK_APP/Contents"
assert_rejected contents-symlink node "$MONITOR_SMOKE_SCRIPT" \
  --app "$CONTENTS_SYMLINK_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'candidate Contents is not a regular directory' "$OUT/contents-symlink.out" \
  || fail 'Contents symlink parent chain was not rejected'

MACOS_SYMLINK_APP="$OUT/MacOSSymlink.app"
MACOS_SYMLINK_TARGET="$OUT/macos-symlink-target"
/bin/mkdir -p "$MACOS_SYMLINK_APP/Contents" "$MACOS_SYMLINK_TARGET"
/usr/bin/plutil -create xml1 "$MACOS_SYMLINK_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string 'CodexPlusPlus' \
  "$MACOS_SYMLINK_APP/Contents/Info.plist"
write_launcher_fixture "$MACOS_SYMLINK_TARGET/CodexPlusPlus"
/bin/ln -s "$MACOS_SYMLINK_TARGET" "$MACOS_SYMLINK_APP/Contents/MacOS"
assert_rejected macos-symlink node "$MONITOR_SMOKE_SCRIPT" \
  --app "$MACOS_SYMLINK_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'candidate MacOS is not a regular directory' "$OUT/macos-symlink.out" \
  || fail 'MacOS symlink to an external executable was not rejected'

assert_rejected missing-info-plist node "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"

/usr/bin/plutil -create xml1 "$FAKE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string '../Codex++' "$FAKE_APP/Contents/Info.plist"
assert_rejected unsafe-bundle-executable node "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'CFBundleExecutable is unsafe' "$OUT/unsafe-bundle-executable.out" \
  || fail 'unsafe CFBundleExecutable explanation missing'

/usr/bin/plutil -replace CFBundleExecutable -string 'Codex++' "$FAKE_APP/Contents/Info.plist"
assert_rejected missing-launcher node "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"

SYMLINK_TARGET="$OUT/symlink-launcher-target"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$SYMLINK_TARGET"
/bin/chmod 755 "$SYMLINK_TARGET"
/bin/ln -s "$SYMLINK_TARGET" "$FAKE_APP/Contents/MacOS/SymlinkLauncher"
/usr/bin/plutil -replace CFBundleExecutable -string 'SymlinkLauncher' "$FAKE_APP/Contents/Info.plist"
assert_rejected symlink-launcher node "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'candidate launcher is missing' "$OUT/symlink-launcher.out" \
  || fail 'symlink CFBundleExecutable target was not rejected'
/usr/bin/plutil -replace CFBundleExecutable -string 'Codex++' "$FAKE_APP/Contents/Info.plist"

FAKE_LAUNCHER="$FAKE_APP/Contents/MacOS/Codex++"
cat > "$FAKE_LAUNCHER" <<'SH'
#!/usr/bin/env bash
capture_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
printf '%s\n' "$@" > "$capture_root/launcher-argv"
/usr/bin/env | /usr/bin/sort > "$capture_root/launcher-env"
exit 0
SH
/bin/chmod 755 "$FAKE_LAUNCHER"

CURRENT_NAMED_APP="$OUT/CodexCurrent.app"
/bin/mkdir -p "$CURRENT_NAMED_APP/Contents/MacOS"
/usr/bin/ditto "$FAKE_LAUNCHER" "$CURRENT_NAMED_APP/Contents/MacOS/CodexPlusPlus"
/usr/bin/plutil -create xml1 "$CURRENT_NAMED_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string 'CodexPlusPlus' "$CURRENT_NAMED_APP/Contents/Info.plist"
assert_rejected current-bundle-executable node "$MONITOR_SMOKE_SCRIPT" \
  --app "$CURRENT_NAMED_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
/usr/bin/grep -Fq 'context meter script is missing' "$OUT/current-bundle-executable.out" \
  || fail 'current CFBundleExecutable was not resolved through Info.plist'

assert_rejected missing-monitor-scripts node "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"

/bin/mkdir -p "$MONITOR_HOME/.config/Codex++/user_scripts"
printf '%s\n' 'const SCRIPT_VERSION = 101;' \
  > "$MONITOR_HOME/.config/Codex++/user_scripts/market-codex-context-used-meter.js"
printf '%s\n' 'const SCRIPT_VERSION = "0.1.7";' \
  > "$MONITOR_HOME/.config/Codex++/user_scripts/market-codex-token-usage.js"
jq -n '{
  enabled: true,
  scripts: {
    "user:market-codex-context-used-meter.js": true,
    "user:market-codex-token-usage.js": true
  }
}' > "$MONITOR_HOME/.config/Codex++/user_scripts.json"

OPENAI_API_KEY='sk-host-smoke-secret' \
CODEX_AUTH_TOKEN='host-auth-token' \
AUTHORIZATION='Bearer host-authorization' \
PATH='/unsafe-host-path' \
LANG='unsafe-host-lang' \
"$NODE_BIN" "$MONITOR_SMOKE_SCRIPT" \
  --app "$FAKE_APP" \
  --home "$MONITOR_HOME" \
  --report "$MONITOR_REPORT" \
  --screenshot "$MONITOR_SCREENSHOT"
[[ "$(/usr/bin/sed -n '1p' "$FAKE_APP/launcher-argv")" == '--debug-port' ]] \
  || fail 'monitor launcher did not receive the frozen debug-port flag'
[[ "$(/usr/bin/sed -n '2p' "$FAKE_APP/launcher-argv")" =~ ^[0-9]+$ ]] \
  || fail 'monitor launcher did not receive a numeric debug port'
/usr/bin/grep -Fxq "HOME=$MONITOR_HOME" "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher HOME was not isolated'
/usr/bin/grep -Fxq "CFFIXED_USER_HOME=$MONITOR_HOME" "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher CFFIXED_USER_HOME was not isolated'
/usr/bin/grep -Fxq "CODEX_HOME=$MONITOR_HOME/.codex" "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher CODEX_HOME was not isolated'
/usr/bin/grep -Fxq "XDG_CONFIG_HOME=$MONITOR_HOME/.config" "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher XDG_CONFIG_HOME was not isolated'
/usr/bin/grep -Fxq 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher PATH was not fixed to the system default'
/usr/bin/grep -Fxq 'LANG=en_US.UTF-8' "$FAKE_APP/launcher-env" \
  || fail 'monitor launcher LANG was not fixed to the safe locale'
if /usr/bin/grep -Eq '^(OPENAI_API_KEY|CODEX_AUTH_TOKEN|AUTHORIZATION|CODEX_PLUS_CONFIG_DIR)=' "$FAKE_APP/launcher-env"; then
  fail 'monitor launcher inherited a sensitive or unsupported host environment variable'
fi
jq -e '
  .schemaVersion == 1 and
  .manualRequired == true and
  .contextMeter.visible == false and
  .tokenUsage.visible == false and
  .contextMeter.version == "101" and
  .tokenUsage.version == "0.1.7" and
  (.contextMeter.before | type == "string") and
  (.contextMeter.after | type == "string") and
  (.tokenUsage.before | type == "string") and
  (.tokenUsage.after | type == "string") and
  (.restartPersistence.contextMeter == true) and
  (.restartPersistence.tokenUsage == true)
' "$MONITOR_REPORT" >/dev/null || fail 'monitor smoke report has an invalid manual result'
if /usr/bin/grep -Eqi 'sk-|[^[:space:]@]+@[^[:space:]@]+|device[[:space:]-]?code|chat[[:space:]]+body' "$MONITOR_REPORT"; then
  fail 'monitor smoke report contains sensitive fixture data'
fi

ROOT="$ROOT" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.ROOT;
const { monitorSnapshot, assertSafeReport } = await import(pathToFileURL(path.join(root, "scripts/run-codex-plus-monitor-smoke.mjs")));
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(root, "tests/script-runtime/node_modules/playwright"));
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const browser = await chromium.launch({
  headless: true,
  ...(executablePath ? { executablePath } : {}),
});
try {
  const page = await browser.newPage();
  await page.setContent(`
    <div id="codex-context-meter" style="width: 10px; height: 10px"></div>
    <div class="codex-token-usage-badge" style="width: 10px; height: 10px"></div>
    <script>
      window.__codexContextMeter = { version: 101, getState: () => ({ lastReading: { used: 120 } }) };
      window.__codexTokenUsageVersion = "0.1.7";
      window.__codexTokenUsage = { last: { usage: { totalTokens: 150 } } };
    </script>
  `);
  assert.deepEqual(await page.evaluate(monitorSnapshot), {
    contextMeter: { visible: true, version: "101", value: "120" },
    tokenUsage: { visible: true, version: "0.1.7", value: "150" },
  });
  assert.throws(
    () => assertSafeReport({ note: "sk-test-secret and person@example.com device code chat body" }),
    /sensitive data/,
  );
} finally {
  await browser.close();
}
NODE

printf '%s\n' 'production-smoke-tests: PASS'
