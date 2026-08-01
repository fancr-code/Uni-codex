#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
OUT="$(mktemp -d "$TEST_TMPDIR/codex-core-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

fail() {
  printf 'installer-core-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

HOME_DIR="$OUT/home"
APPLICATIONS_DIR="$OUT/Applications"
PAYLOAD_ROOT="$OUT/payloads"
REPORT_DIR="$OUT/reports"
mkdir -p "$HOME_DIR" "$APPLICATIONS_DIR" "$PAYLOAD_ROOT" "$REPORT_DIR"
cp "$ROOT/tests/fixtures/payload-manifest.test.json" "$PAYLOAD_ROOT/payload-manifest.json"
cp "$ROOT/Resources/model-catalog.json" "$PAYLOAD_ROOT/model-catalog.json"
/usr/bin/ditto "$ROOT/tests/fixtures/apps" "$PAYLOAD_ROOT/apps"

FAKE_SUPPORT="$OUT/installer-support"
cat > "$FAKE_SUPPORT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
case "$command_name" in
  backup-identifier)
    identifier_value="$(( $(date +%s) * 1000000 + $$ ))"
    printf '{"identifier":"%020d-00000000-0000-0000-0000-000000000000"}\n' "$identifier_value"
    ;;
  build-complete-inventory)
    created_at="$3"
    printf '{"schemaVersion":2,"createdAt":"%s","entries":[' "$created_at"
    separator=''
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || exit 65
      printf '%s%s' "$separator" "$entry"
      separator=,
    done
    printf ']}\n'
    ;;
  validate-complete-inventory)
    inventory="$3"
    entry_count="$(/usr/bin/plutil -extract entries raw -expect array -o - "$inventory")"
    entry_index=0
    while [[ "$entry_index" -lt "$entry_count" ]]; do
      key="$(/usr/bin/plutil -extract "entries.$entry_index.key" raw -o - "$inventory")"
      kind="$(/usr/bin/plutil -extract "entries.$entry_index.kind" raw -o - "$inventory")"
      existed="$(/usr/bin/plutil -extract "entries.$entry_index.existed" raw -o - "$inventory")"
      relative=''
      if [[ "$existed" == true ]]; then
        relative="$(/usr/bin/plutil -extract "entries.$entry_index.backupRelativePath" raw -o - "$inventory")"
      fi
      printf '%s\t%s\t%s\t%s\n' "$key" "$kind" "$existed" "$relative"
      entry_index=$((entry_index + 1))
    done
    ;;
  hardware-architecture)
    printf '{"architecture":"%s"}\n' "${REAL_ARCH_OVERRIDE:-arm64}"
    ;;
  manifest-validate)
    printf '%s\n' '{"payloadCount":7,"schemaVersion":1,"status":"valid"}'
    ;;
  validate-install-request)
    cat >/dev/null
    printf '%s\n' '{"modelCount":1,"modelSource":"offlineSnapshot","provider":"deepseek","status":"valid"}'
    ;;
  payload-resolve)
    component="$5"
    architecture="$7"
    if [[ "$component" == "chatgpt" ]]; then
      printf '{"architecture":"%s","bundleIdentifier":"com.openai.codex","format":"directory","id":"chatgpt-codex-%s","relativePath":"apps/%s/ChatGPT.app","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","teamIdentifier":"2DC432GLL2","version":"26.715.52143"}\n' "$architecture" "$architecture" "$architecture"
    else
      printf '{"architecture":"%s","compatibilityRevision":"cross-provider-content-v1","format":"directory","id":"codex-plus-plus-%s","relativePath":"apps/%s/CodexPlusPlus","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","version":"1.2.41"}\n' "$architecture" "$architecture" "$architecture"
    fi
    ;;
  apply-config)
    request_file="$(mktemp "${TMPDIR:-/tmp}/fake-request.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    cat > "$request_file"
    root="$3"
    if [[ "${FAKE_APPLY_FAILURE:-0}" == "1" ]]; then
      mkdir -p "$root/.codex"
      printf '%s\n' 'partially-mutated-before-apply-failure' > "$root/.codex/config.toml"
      cat "$request_file" >&2
      exit 65
    fi
    backup="${7:-$root/Library/Application Support/Codex One Click Installer/backups/fake-backup}"
    mkdir -p \
      "$backup" \
      "$root/.codex" \
      "$root/.codex-session-delete" \
      "$root/Library/Application Support/Codex One Click Installer"
    printf '%s\n' 'model = "configured"' > "$root/.codex/config.toml"
    printf '%s\n' '{}' > "$root/.codex/auth.json"
    printf '%s\n' '{}' > "$root/.codex-session-delete/settings.json"
    printf '%s\n' '{"schemaVersion":1}' \
      > "$root/Library/Application Support/Codex One Click Installer/install-expectation.json"
    printf '{"backupDirectory":"%s","managedProviderID":"codex-one-click-deepseek"}\n' "$backup"
    ;;
  chatgpt-auth-status)
    printf '%s\n' '{"authenticated":true,"authenticationMode":"chatgpt","status":"checked"}'
    ;;
  verify-config)
    printf '%s\n' '{"authenticationMode":"pureAPI","defaultModel":"deepseek-v4-flash","modelCount":1,"provider":"deepseek","status":"pass"}'
    ;;
  verify-plugin-config)
    printf '%s\n' '{"marketplaceCount":3,"pluginCount":9,"status":"pass"}'
    ;;
  snapshot-config)
    root="$3"
    backup="$5"
    mkdir -p "$backup"
    if [[ -f "$root/.codex/config.toml" ]]; then
      cp "$root/.codex/config.toml" "$backup/original-config.toml"
    else
      : > "$backup/config-was-absent"
    fi
    printf '%s\n' '{"schemaVersion":2,"createdAt":"2026-07-23T00:00:00Z","entries":[]}' \
      > "$backup/inventory.json"
    ;;
  validate-config-backup)
    exit 0
    ;;
  restore-config)
    if [[ -n "${FAKE_RESTORE_FAILURE_FILE:-}" ]]; then
      printf '%s\n' failure >> "$FAKE_RESTORE_FAILURE_FILE"
      exit 67
    fi
    root="$3"
    backup="$5"
    if [[ -f "$backup/original-config.toml" ]]; then
      mkdir -p "$root/.codex"
      cp "$backup/original-config.toml" "$root/.codex/config.toml"
    elif [[ -f "$backup/config-was-absent" ]]; then
      rm -f "$root/.codex/config.toml"
    fi
    exit 0
    ;;
  *)
    printf '%s\n' 'unsupported fake command' >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKE_SUPPORT"

run_core() {
  TEST_MODE=1 \
  HOME="$HOME_DIR" \
  APPLICATIONS_DIR="$APPLICATIONS_DIR" \
  PAYLOAD_ROOT="$PAYLOAD_ROOT" \
  REPORT_DIR="$REPORT_DIR" \
  SUPPORT_TOOL="$FAKE_SUPPORT" \
  REAL_ARCH_OVERRIDE=arm64 \
  MACOS_VERSION_OVERRIDE=14.6 \
  DISK_BYTES_OVERRIDE=10000000000 \
  bash "$ROOT/Resources/installer-core.sh" "$@"
}

GUARD_LIBRARY="$OUT/installer-core-guards.sh"
sed '/^command_name="${1:-}"/,$d' "$ROOT/Resources/installer-core.sh" > "$GUARD_LIBRARY"

assert_begin_transaction_failure_propagates() {
  local readonly_tmp="$OUT/read-only-transaction-tmp"
  local protected_target="$APPLICATIONS_DIR/ChatGPT.app"
  local output status
  mkdir "$readonly_tmp"
  mkdir -p "$protected_target"
  printf '%s\n' keep-existing-target > "$protected_target/sentinel"
  cp "$protected_target/sentinel" "$OUT/transaction-failure-target-before"
  chmod 500 "$readonly_tmp"
  set +e
  output="$(
    TEST_MODE=1 \
    HOME="$HOME_DIR" \
    APPLICATIONS_DIR="$APPLICATIONS_DIR" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$REPORT_DIR" \
    SUPPORT_TOOL="$FAKE_SUPPORT" \
    TMPDIR="$readonly_tmp" \
    /bin/bash -c '
      source "$1"
      begin_transaction || exit $?
      printf "transaction_active=%s transaction_dir=%s journal=%s\n" \
        "$TRANSACTION_ACTIVE" "$TRANSACTION_DIR" "$JOURNAL_FILE"
    ' transaction-failure "$GUARD_LIBRARY" 2>&1
  )"
  status=$?
  set -e
  chmod 700 "$readonly_tmp"
  [[ "$status" -ne 0 ]] || fail "begin_transaction swallowed mktemp failure: $output"
  [[ "$output" != *'transaction_active=1'* ]] \
    || fail "begin_transaction activated a failed transaction: $output"
  cmp "$OUT/transaction-failure-target-before" "$protected_target/sentinel" \
    || fail 'begin_transaction failure changed the protected application target'
  [[ "$(find "$readonly_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 0 ]] \
    || fail 'begin_transaction failure left transaction artifacts behind'
  rm -R "$protected_target"
}

assert_begin_transaction_failure_propagates

assert_failed_rollback_preserves_recovery_material() {
  local transaction="$OUT/failed-rollback-transaction"
  local backup="$transaction/app-backup"
  local journal="$transaction/journal"
  local backup_secret='sk-rollback-recovery-secret'
  local output status
  mkdir -p "$backup"
  printf '%s\n' "$backup_secret" > "$backup/sentinel"
  printf 'backup_app|%s|%s\n' "$APPLICATIONS_DIR/ChatGPT.app" "$backup" > "$journal"
  : > "$transaction/install-request.json"
  : > "$transaction/mount-points"
  chmod 000 "$journal"

  set +e
  output="$(
    TEST_MODE=1 \
    HOME="$HOME_DIR" \
    APPLICATIONS_DIR="$APPLICATIONS_DIR" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$REPORT_DIR" \
    SUPPORT_TOOL="$FAKE_SUPPORT" \
    /bin/bash -c '
      source "$1"
      TRANSACTION_DIR="$2"
      JOURNAL_FILE="$2/journal"
      REQUEST_FILE="$2/install-request.json"
      MOUNT_POINTS_FILE="$2/mount-points"
      TRANSACTION_ACTIVE=1
      exit 75
    ' rollback-failure "$GUARD_LIBRARY" "$transaction" 2>&1
  )"
  status=$?
  set -e

  if [[ -e "$journal" ]]; then
    chmod 600 "$journal"
  fi
  [[ "$status" -eq 70 ]] || fail "failed rollback did not return dedicated status 70: status=$status output=$output"
  [[ -d "$transaction" ]] || fail 'failed rollback deleted the transaction directory'
  [[ -f "$journal" ]] || fail 'failed rollback deleted the transaction journal'
  cmp "$backup/sentinel" <(printf '%s\n' "$backup_secret") \
    || fail 'failed rollback deleted or changed the application backup'
  [[ "$output" != *"$backup_secret"* ]] \
    || fail 'failed rollback exposed recovery material contents'
  [[ "$output" == *'"kind":"rollback_failed"'* ]] \
    || fail "failed rollback did not emit rollback_failed: $output"
  [[ "$output" == *'"reason":"journal_read_failed"'* ]] \
    || fail "failed rollback did not report a structured reason: $output"
  [[ "$output" == *'"originalStatus":75'* ]] \
    || fail "failed rollback omitted the original status: $output"
  [[ "$output" == *"\"recoveryPath\":\"$transaction\""* ]] \
    || fail "failed rollback omitted the recovery material path: $output"
  [[ "$output" != *'"kind":"rollback_completed"'* ]] \
    || fail "failed rollback incorrectly reported completion: $output"
}

assert_failed_rollback_preserves_recovery_material

assert_guard_context_rejects_report_symlink() {
  local context="$1"
  local escape="$OUT/$context-report-escape"
  local report_link="$OUT/$context-report-link"
  local output status mode_before
  mkdir -p "$escape"
  printf '%s\n' sentinel > "$escape/sentinel"
  cp "$escape/sentinel" "$OUT/$context-sentinel-before"
  chmod 755 "$escape"
  mode_before="$(stat -f '%Lp' "$escape")"
  ln -s "$escape" "$report_link"
  set +e
  output="$(
    TEST_MODE=1 \
    HOME="$HOME_DIR" \
    APPLICATIONS_DIR="$APPLICATIONS_DIR" \
    PAYLOAD_ROOT="$PAYLOAD_ROOT" \
    REPORT_DIR="$report_link" \
    SUPPORT_TOOL="$FAKE_SUPPORT" \
    GUARD_CONTEXT="$context" \
    /bin/bash -c '
      source "$1"
      case "$GUARD_CONTEXT" in
        substitution)
          report_path="$(prepare_report provider backup)"
          exit $?
          ;;
        conditional)
          if ! validate_managed_paths; then
            exit 65
          fi
          exit 0
          ;;
        or_list)
          validate_managed_paths || exit $?
          exit 0
          ;;
        *) exit 99 ;;
      esac
    ' guard-context "$GUARD_LIBRARY" 2>&1
  )"
  status=$?
  set -e
  [[ "$status" -eq 65 ]] || fail "$context guard context continued after rejection: $output"
  cmp "$OUT/$context-sentinel-before" "$escape/sentinel" \
    || fail "$context guard context modified the external sentinel"
  [[ "$(find "$escape" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "$context guard context created an external file"
  [[ "$(stat -f '%Lp' "$escape")" == "$mode_before" ]] \
    || fail "$context guard context changed external directory metadata"
}

assert_guard_context_rejects_report_symlink substitution
assert_guard_context_rejects_report_symlink conditional
assert_guard_context_rejects_report_symlink or_list

preflight="$(run_core preflight)"
[[ "$preflight" == *'"architecture":"arm64"'* ]]
[[ "$preflight" == *'"mode":"fresh"'* ]]
[[ "$preflight" == *'"runningApplications":[]'* ]]
[[ "$preflight" == *'"availableDiskBytes":10000000000'* ]]

auth_status="$(run_core auth-status)"
[[ "$auth_status" == '{"authenticated":true,"authenticationMode":"chatgpt","status":"checked"}' ]]

set +e
invalid_auth_status_output="$(run_core auth-status unexpected 2>&1)"
invalid_auth_status_code=$?
set -e
[[ "$invalid_auth_status_code" -eq 64 ]]
[[ "$invalid_auth_status_output" == *'"code":"invalid_arguments"'* ]]

secret='sk-super-secret-value'
export FAKE_APPLY_FAILURE=1
set +e
failure_output="$(printf '{"provider":"deepseek","apiKey":"%s","defaultModel":"deepseek-v4-flash","availableModels":["deepseek-v4-flash"]}' "$secret" | run_core install --request-stdin 2>&1)"
failure_status=$?
set -e
unset FAKE_APPLY_FAILURE
[[ "$failure_status" -ne 0 ]]
[[ "$failure_output" != *"$secret"* ]]
[[ "$failure_output" == *'[REDACTED]'* ]]
[[ "$failure_output" == *'install_failed'* ]]
[[ ! -e "$HOME_DIR/.codex/config.toml" ]] \
  || fail 'partial apply-config failure was not restored from the pre-mutation snapshot'

success_output="$(printf '{"provider":"deepseek","apiKey":"%s","defaultModel":"deepseek-v4-flash","availableModels":["deepseek-v4-flash"]}' "$secret" | run_core install --request-stdin 2>&1)"
[[ "$success_output" == *'install_completed'* ]]
[[ "$success_output" != *"$secret"* ]]
report="$(find "$REPORT_DIR" -name 'install-report-*.md' -type f | head -n 1)"
[[ -n "$report" ]]
! rg -q "$secret|Bearer[[:space:]]+" "$report"

RESTORE_FAILURE_FILE="$OUT/restore-failures"
set +e
restore_failure_output="$(FAKE_RESTORE_FAILURE_FILE="$RESTORE_FAILURE_FILE" run_core restore-latest 2>&1)"
restore_failure_status=$?
set -e
[[ "$restore_failure_status" -eq 70 ]] \
  || fail "double restore failure returned $restore_failure_status: $restore_failure_output"
[[ "$(wc -l < "$RESTORE_FAILURE_FILE" | tr -d ' ')" -eq 2 ]] \
  || fail 'restore failure did not attempt the pre-restore recovery snapshot'
[[ "$restore_failure_output" == *'"kind":"rollback_failed"'* ]] \
  || fail 'double restore failure omitted rollback_failed'
[[ "$restore_failure_output" == *'"code":"restore_failed"'* ]] \
  || fail 'double restore failure omitted restore_failed'
restore_recovery_path="$(printf '%s\n' "$restore_failure_output" \
  | sed -n 's/.*"recoveryPath":"\([^"]*\)".*/\1/p' | tail -n 1)"
[[ "$restore_recovery_path" == *'/backups/.pending-'* && -d "$restore_recovery_path" ]] \
  || fail "double restore failure deleted recovery snapshot: $restore_recovery_path"
[[ -f "$restore_recovery_path/inventory.json" && -f "$restore_recovery_path/configuration/inventory.json" ]] \
  || fail 'preserved recovery snapshot is incomplete'
post_failure_preflight="$(run_core preflight)"
[[ "$post_failure_preflight" != *"$restore_recovery_path"* ]] \
  || fail 'preserved pending recovery snapshot became latest'

RUNNING_APPS_OVERRIDE=ChatGPT running_output="$(RUNNING_APPS_OVERRIDE=ChatGPT run_core preflight)"
[[ "$running_output" == *'"runningApplications":["ChatGPT"]'* ]]
set +e
blocked_output="$(printf '{"provider":"deepseek","apiKey":"%s","defaultModel":"deepseek-v4-flash","availableModels":["deepseek-v4-flash"]}' "$secret" | RUNNING_APPS_OVERRIDE=ChatGPT run_core install --request-stdin 2>&1)"
blocked_status=$?
set -e
[[ "$blocked_status" -ne 0 ]]
[[ "$blocked_output" == *'running_apps'* ]]

set +e
production_override_output="$(HOME="$HOME_DIR" PAYLOAD_ROOT="$PAYLOAD_ROOT" bash "$ROOT/Resources/installer-core.sh" preflight 2>&1)"
production_override_status=$?
set -e
[[ "$production_override_status" -ne 0 ]]
[[ "$production_override_output" == *'unsafe_override'* ]]

printf '%s\n' 'installer-core-tests: PASS'
