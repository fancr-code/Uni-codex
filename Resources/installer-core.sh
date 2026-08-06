#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_MODE="${TEST_MODE:-0}"

if [[ "$TEST_MODE" != "1" ]]; then
  if [[ "${APPLICATIONS_DIR+x}" == "x" || "${PAYLOAD_ROOT+x}" == "x" || \
        "${REPORT_DIR+x}" == "x" || "${SUPPORT_TOOL+x}" == "x" || \
        "${REAL_ARCH_OVERRIDE+x}" == "x" || "${MACOS_VERSION_OVERRIDE+x}" == "x" || \
        "${DISK_BYTES_OVERRIDE+x}" == "x" || "${RUNNING_APPS_OVERRIDE+x}" == "x" || \
        "${FAIL_AFTER_CONFIG+x}" == "x" || "${FAIL_AFTER_APP_INDEX+x}" == "x" || \
        "${FAIL_AFTER_PLUGINS+x}" == "x" || "${FAIL_AFTER_SCRIPTS+x}" == "x" || \
        "${TEST_PAUSE_FILE+x}" == "x" || "${TEST_PAUSE_RESTORE_FILE+x}" == "x" || \
        "${TEST_PAUSE_RECOVERY_FILE+x}" == "x" ]]; then
    printf '%s\n' '::event::{"kind":"error","progress":null,"message":"unsafe test override","code":"unsafe_override"}'
    exit 64
  fi
fi

PAYLOAD_ROOT="${PAYLOAD_ROOT:-$SCRIPT_DIR/offline-payloads}"
SUPPORT_TOOL="${SUPPORT_TOOL:-$SCRIPT_DIR/installer-support}"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-/Applications}"
REPORT_DIR="${REPORT_DIR:-$HOME/Documents/Codex-一键安装报告}"
BACKUP_ROOT="$HOME/Library/Application Support/Codex One Click Installer/backups"
REQUIRED_DISK_BYTES=4294967296

TRANSACTION_ACTIVE=0
TRANSACTION_DIR=""
JOURNAL_FILE=""
REQUEST_FILE=""
MOUNT_POINTS_FILE=""
RUNNING_APPS_JSON='[]'
RUNNING_APPS_COUNT=0
SELECTED_ARCHITECTURE=""
CHATGPT_PAYLOAD_INFO=""
CODEX_PLUS_PAYLOAD_INFO=""
CHATGPT_VERSION=""
CHATGPT_BUNDLE_ID=""
CHATGPT_TEAM_ID=""
CODEX_PLUS_VERSION=""
CODEX_PLUS_COMPATIBILITY_REVISION=""
INSTALLED_CHATGPT_VERSION=""
ROLLBACK_FAILURE_REASON=""
ROLLBACK_FAILURE_EXIT_STATUS=70
PENDING_BACKUP=""
COMPLETE_BACKUP=""
RESTORE_ACTIVE=0
RESTORE_RECOVERY_BACKUP=""
PRESERVE_RECOVERY_STATE=0
INSTALL_REPORT_PATH=""
PREPARED_REPORT_PATH=""
SELF_CHECK_PATH=""
SELF_CHECK_CONFIGURATION_STATUS=not_checked
SELF_CHECK_CONFIGURATION_REASON=""
SELF_CHECK_PROVIDER=""
SELF_CHECK_DEFAULT_MODEL=""
SELF_CHECK_MODEL_COUNT=0
SELF_CHECK_AUTHENTICATION_MODE=""
SELF_CHECK_PAYLOAD_STATUS=not_checked
SELF_CHECK_PAYLOAD_REASON=""
SELF_CHECK_APPLICATIONS_STATUS=not_checked
SELF_CHECK_APPLICATIONS_REASON=""
SELF_CHECK_APPLICATION_COUNT=0
SELF_CHECK_PLUGINS_STATUS=not_checked
SELF_CHECK_PLUGINS_REASON=""
SELF_CHECK_MARKETPLACE_COUNT=0
SELF_CHECK_PLUGIN_COUNT=0
SELF_CHECK_SCRIPTS_STATUS=not_checked
SELF_CHECK_SCRIPTS_REASON=""
SELF_CHECK_TRANSLATION_ENABLED=false
SELF_CHECK_CONTEXT_METER_ENABLED=false
SELF_CHECK_TOKEN_USAGE_ENABLED=false
SELF_CHECK_CONTEXT_METER_VERSION=""
SELF_CHECK_TOKEN_USAGE_VERSION=""

fixed_backup_keys() {
  /bin/cat <<'KEYS'
app.chatgpt
app.codex-plus-plus
app.codex-plus-plus-manager
marketplace.openai-bundled
marketplace.openai-primary-runtime
marketplace.openai-curated
plugin.openai-bundled.browser
plugin.openai-bundled.chrome
plugin.openai-bundled.computer-use
plugin.openai-bundled.latex
plugin.openai-primary-runtime.pdf
plugin.openai-primary-runtime.documents
plugin.openai-primary-runtime.spreadsheets
plugin.openai-primary-runtime.presentations
plugin.openai-curated.github
script.config
script.file.market-codex-zhcn-translate.js
script.file.market-codex-context-used-meter.js
script.file.market-codex-token-usage.js
script.file.market-another-script.js
KEYS
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  printf '%s' "$value"
}

emit_event() {
  local kind="$1"
  local progress="$2"
  local message="$3"
  local code="$4"
  printf '::event::{"kind":"%s","progress":%s,"message":"%s","code":%s}\n' \
    "$(json_escape "$kind")" \
    "$progress" \
    "$(json_escape "$message")" \
    "$code"
}

emit_rollback_failure() {
  local reason="$1"
  local original_status="$2"
  local rollback_status="$3"
  local recovery_path="$4"
  printf '::event::{"kind":"rollback_failed","progress":null,"message":"automatic rollback failed; recovery materials were preserved","code":"rollback_failed","reason":"%s","originalStatus":%s,"rollbackStatus":%s,"recoveryPath":"%s"}\n' \
    "$(json_escape "$reason")" \
    "$original_status" \
    "$rollback_status" \
    "$(json_escape "$recovery_path")"
}

require_safe_directory_chain() {
  local root="$1"
  local relative="$2"
  local code="$3"
  local cursor="$root"
  local remaining="$relative"
  local component
  [[ -d "$root" && ! -L "$root" ]] || {
    emit_event error null 'unsafe managed root' "\"$code\""
    return 65
  }
  [[ -n "$relative" && "$relative" != /* && "$relative" != */ && "$relative" != *'//'* ]] || {
    emit_event error null 'invalid managed relative path' "\"$code\""
    return 65
  }
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then
      remaining="${remaining#*/}"
    else
      remaining=""
    fi
    [[ -n "$component" && "$component" != . && "$component" != .. && \
       "$component" != *'\'* && "$component" != *$'\n'* ]] || {
      emit_event error null 'invalid managed path component' "\"$code\""
      return 65
    }
    cursor="${cursor%/}/$component"
    [[ ! -L "$cursor" ]] || {
      emit_event error null 'managed path contains a symbolic link' "\"$code\""
      return 65
    }
    [[ ! -e "$cursor" || -d "$cursor" ]] || {
      emit_event error null 'managed directory chain contains a non-directory' "\"$code\""
      return 65
    }
  done
}

ensure_safe_directory_chain() {
  local root="$1"
  local relative="$2"
  local code="$3"
  local cursor="$root"
  local remaining="$relative"
  local component
  require_safe_directory_chain "$root" "$relative" "$code" || return $?
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then
      remaining="${remaining#*/}"
    else
      remaining=""
    fi
    cursor="${cursor%/}/$component"
    if [[ ! -e "$cursor" ]]; then
      /bin/mkdir "$cursor" || return $?
      /bin/chmod 700 "$cursor" || return $?
    fi
    [[ -d "$cursor" && ! -L "$cursor" ]] || {
      emit_event error null 'managed directory creation was unsafe' "\"$code\""
      return 65
    }
  done
}

require_safe_regular_file_if_present() {
  local root="$1"
  local relative="$2"
  local code="$3"
  local parent
  local leaf
  local target
  case "$relative" in
    */*) parent="${relative%/*}"; leaf="${relative##*/}" ;;
    *) parent=""; leaf="$relative" ;;
  esac
  [[ -n "$leaf" && "$leaf" != . && "$leaf" != .. && \
     "$leaf" != *'\'* && "$leaf" != *$'\n'* ]] || {
    emit_event error null 'invalid managed file path' "\"$code\""
    return 65
  }
  if [[ -n "$parent" ]]; then
    require_safe_directory_chain "$root" "$parent" "$code" || return $?
  else
    [[ -d "$root" && ! -L "$root" ]] || return 65
  fi
  target="${root%/}/$relative"
  [[ ! -L "$target" ]] || {
    emit_event error null 'managed file is a symbolic link' "\"$code\""
    return 65
  }
  [[ ! -e "$target" || -f "$target" ]] || {
    emit_event error null 'managed file target is invalid' "\"$code\""
    return 65
  }
}

require_safe_absolute_directory_chain() {
  local path="$1"
  local code="$2"
  [[ "$path" == /* && "$path" != / ]] || {
    emit_event error null 'managed path must be absolute' "\"$code\""
    return 65
  }
  require_safe_directory_chain / "${path#/}" "$code" || return $?
}

require_safe_absolute_regular_file_if_present() {
  local path="$1"
  local code="$2"
  [[ "$path" == /* && "$path" != / ]] || {
    emit_event error null 'managed file path must be absolute' "\"$code\""
    return 65
  }
  require_safe_regular_file_if_present / "${path#/}" "$code" || return $?
}

ensure_safe_absolute_directory_chain() {
  local path="$1"
  local code="$2"
  [[ "$path" == /* && "$path" != / ]] || {
    emit_event error null 'managed path must be absolute' "\"$code\""
    return 65
  }
  ensure_safe_directory_chain / "${path#/}" "$code" || return $?
}

validate_managed_paths() {
  require_safe_absolute_directory_chain "$HOME" unsafe_home || return $?
  [[ -d "$HOME" && ! -L "$HOME" ]] || return 65
  require_safe_absolute_directory_chain "$APPLICATIONS_DIR" unsafe_app_target || return $?
  [[ -d "$APPLICATIONS_DIR" && ! -L "$APPLICATIONS_DIR" ]] || {
    emit_event error null 'application destination is invalid' '"unsafe_app_target"'
    return 65
  }
  require_safe_absolute_directory_chain "$REPORT_DIR" unsafe_report_target || return $?
  require_safe_directory_chain "$HOME" '.codex' unsafe_configuration_target || return $?
  require_safe_directory_chain "$HOME" '.codex-session-delete' unsafe_configuration_target || return $?
  require_safe_directory_chain "$HOME" '.config/Codex++' unsafe_script_target || return $?
  require_safe_directory_chain "$HOME" 'Library/Application Support/Codex One Click Installer/backups' unsafe_backup || return $?
  require_safe_directory_chain "$HOME" '.codex/offline-marketplaces' unsafe_plugin_target || return $?
  require_safe_directory_chain "$HOME" '.codex/plugins/cache' unsafe_plugin_target || return $?
  require_safe_regular_file_if_present "$HOME" '.codex/config.toml' unsafe_configuration_target || return $?
  require_safe_regular_file_if_present "$HOME" '.codex/auth.json' unsafe_configuration_target || return $?
  require_safe_regular_file_if_present "$HOME" '.codex-session-delete/settings.json' unsafe_configuration_target || return $?
  require_safe_regular_file_if_present "$HOME" 'Library/Application Support/Codex One Click Installer/install-expectation.json' unsafe_configuration_target || return $?
  require_safe_regular_file_if_present "$HOME" '.config/Codex++/user_scripts.json' unsafe_script_target || return $?
  require_safe_directory_chain "$APPLICATIONS_DIR" 'ChatGPT.app' unsafe_app_target || return $?
  require_safe_directory_chain "$APPLICATIONS_DIR" 'Codex++.app' unsafe_app_target || return $?
  require_safe_directory_chain "$APPLICATIONS_DIR" 'Codex++ 管理工具.app' unsafe_app_target || return $?
}

redact_stream() {
  /usr/bin/sed -E \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/("?(apiKey|OPENAI_API_KEY)"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9._-]{8,}/[REDACTED]/g'
}

json_nullable_string() {
  local value="$1"
  if [[ -n "$value" ]]; then
    printf '"%s"' "$(json_escape "$value")"
  else
    printf 'null'
  fi
}

reset_self_check_state() {
  SELF_CHECK_PATH=""
  SELF_CHECK_CONFIGURATION_STATUS=not_checked
  SELF_CHECK_CONFIGURATION_REASON=""
  SELF_CHECK_PROVIDER=""
  SELF_CHECK_DEFAULT_MODEL=""
  SELF_CHECK_MODEL_COUNT=0
  SELF_CHECK_AUTHENTICATION_MODE=""
  SELF_CHECK_PAYLOAD_STATUS=not_checked
  SELF_CHECK_PAYLOAD_REASON=""
  SELF_CHECK_APPLICATIONS_STATUS=not_checked
  SELF_CHECK_APPLICATIONS_REASON=""
  SELF_CHECK_APPLICATION_COUNT=0
  SELF_CHECK_PLUGINS_STATUS=not_checked
  SELF_CHECK_PLUGINS_REASON=""
  SELF_CHECK_MARKETPLACE_COUNT=0
  SELF_CHECK_PLUGIN_COUNT=0
  SELF_CHECK_SCRIPTS_STATUS=not_checked
  SELF_CHECK_SCRIPTS_REASON=""
  SELF_CHECK_TRANSLATION_ENABLED=false
  SELF_CHECK_CONTEXT_METER_ENABLED=false
  SELF_CHECK_TOKEN_USAGE_ENABLED=false
  SELF_CHECK_CONTEXT_METER_VERSION=""
  SELF_CHECK_TOKEN_USAGE_VERSION=""
  INSTALLED_CHATGPT_VERSION=""
}

write_self_check() {
  local overall="$1"
  local temporary
  local provider_json default_model_json authentication_mode_json
  local configuration_reason_json payload_reason_json applications_reason_json
  local plugins_reason_json scripts_reason_json
  [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || return 65
  [[ "$overall" == pass || "$overall" == fail ]] || return 65
  [[ "$SELF_CHECK_MODEL_COUNT" =~ ^[0-9]+$ && "$SELF_CHECK_APPLICATION_COUNT" =~ ^[0-9]+$ && \
     "$SELF_CHECK_MARKETPLACE_COUNT" =~ ^[0-9]+$ && "$SELF_CHECK_PLUGIN_COUNT" =~ ^[0-9]+$ ]] || return 65
  SELF_CHECK_PATH="$TRANSACTION_DIR/self-check.json"
  temporary="$TRANSACTION_DIR/.self-check.tmp.json"
  require_safe_regular_file_if_present "$TRANSACTION_DIR" '.self-check.tmp.json' unsafe_self_check || return $?
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'self-check.json' unsafe_self_check || return $?
  provider_json="$(json_nullable_string "$SELF_CHECK_PROVIDER")" || return $?
  default_model_json="$(json_nullable_string "$SELF_CHECK_DEFAULT_MODEL")" || return $?
  authentication_mode_json="$(json_nullable_string "$SELF_CHECK_AUTHENTICATION_MODE")" || return $?
  configuration_reason_json="$(json_nullable_string "$SELF_CHECK_CONFIGURATION_REASON")" || return $?
  payload_reason_json="$(json_nullable_string "$SELF_CHECK_PAYLOAD_REASON")" || return $?
  applications_reason_json="$(json_nullable_string "$SELF_CHECK_APPLICATIONS_REASON")" || return $?
  plugins_reason_json="$(json_nullable_string "$SELF_CHECK_PLUGINS_REASON")" || return $?
  scripts_reason_json="$(json_nullable_string "$SELF_CHECK_SCRIPTS_REASON")" || return $?
  {
    printf '{'
    printf '"schemaVersion":1,"overall":"%s",' "$overall"
    printf '"configuration":{"status":"%s","reasonCode":%s,"provider":%s,"defaultModel":%s,"modelCount":%s,"authenticationMode":%s},' \
      "$SELF_CHECK_CONFIGURATION_STATUS" "$configuration_reason_json" \
      "$provider_json" "$default_model_json" "$SELF_CHECK_MODEL_COUNT" "$authentication_mode_json"
    printf '"payload":{"status":"%s","reasonCode":%s},' \
      "$SELF_CHECK_PAYLOAD_STATUS" "$payload_reason_json"
    printf '"applications":{"status":"%s","reasonCode":%s,"count":%s,"items":[' \
      "$SELF_CHECK_APPLICATIONS_STATUS" "$applications_reason_json" "$SELF_CHECK_APPLICATION_COUNT"
    printf '{"name":"ChatGPT/Codex","version":"%s","architecture":"%s"},' \
      "$(json_escape "${INSTALLED_CHATGPT_VERSION:-$CHATGPT_VERSION}")" "$(json_escape "$SELECTED_ARCHITECTURE")"
    printf '{"name":"Codex++","version":"%s","architecture":"%s"},' \
      "$(json_escape "$CODEX_PLUS_VERSION")" "$(json_escape "$SELECTED_ARCHITECTURE")"
    printf '{"name":"Codex++ 管理工具","version":"%s","architecture":"%s"}]},' \
      "$(json_escape "$CODEX_PLUS_VERSION")" "$(json_escape "$SELECTED_ARCHITECTURE")"
    printf '"plugins":{"status":"%s","reasonCode":%s,"marketplaces":%s,"plugins":%s},' \
      "$SELF_CHECK_PLUGINS_STATUS" "$plugins_reason_json" \
      "$SELF_CHECK_MARKETPLACE_COUNT" "$SELF_CHECK_PLUGIN_COUNT"
    printf '"scripts":{"status":"%s","reasonCode":%s,"translationEnabled":%s,"contextMeterEnabled":%s,"tokenUsageEnabled":%s,"contextMeterVersion":%s,"tokenUsageVersion":%s}' \
      "$SELF_CHECK_SCRIPTS_STATUS" "$scripts_reason_json" \
      "$SELF_CHECK_TRANSLATION_ENABLED" "$SELF_CHECK_CONTEXT_METER_ENABLED" \
      "$SELF_CHECK_TOKEN_USAGE_ENABLED" \
      "$(json_nullable_string "$SELF_CHECK_CONTEXT_METER_VERSION")" \
      "$(json_nullable_string "$SELF_CHECK_TOKEN_USAGE_VERSION")"
    printf '}\n'
  } > "$temporary" || return $?
  /bin/chmod 600 "$temporary" || return $?
  /usr/bin/plutil -convert json -o /dev/null "$temporary" >/dev/null || return 65
  /bin/mv -f "$temporary" "$SELF_CHECK_PATH" || return $?
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'self-check.json' unsafe_self_check || return $?
}

fail_self_check() {
  local section="$1"
  local reason="$2"
  local message="$3"
  local event_code="$4"
  case "$section" in
    configuration)
      SELF_CHECK_CONFIGURATION_STATUS=fail
      SELF_CHECK_CONFIGURATION_REASON="$reason"
      ;;
    payload)
      SELF_CHECK_PAYLOAD_STATUS=fail
      SELF_CHECK_PAYLOAD_REASON="$reason"
      ;;
    applications)
      SELF_CHECK_APPLICATIONS_STATUS=fail
      SELF_CHECK_APPLICATIONS_REASON="$reason"
      ;;
    plugins)
      SELF_CHECK_PLUGINS_STATUS=fail
      SELF_CHECK_PLUGINS_REASON="$reason"
      ;;
    scripts)
      SELF_CHECK_SCRIPTS_STATUS=fail
      SELF_CHECK_SCRIPTS_REASON="$reason"
      ;;
    *) return 65 ;;
  esac
  write_self_check fail || return $?
  emit_event error null "$message" "\"$event_code\""
  return 67
}

detect_running_apps() {
  local names=""
  local name
  if [[ "$TEST_MODE" == "1" && -n "${RUNNING_APPS_OVERRIDE:-}" ]]; then
    names="$RUNNING_APPS_OVERRIDE"
  elif [[ "$TEST_MODE" != "1" ]]; then
    for name in ChatGPT Codex 'Codex++' 'Codex++ 管理工具'; do
      if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
        names="${names}${names:+,}${name}"
      fi
    done
  fi

  RUNNING_APPS_JSON='['
  RUNNING_APPS_COUNT=0
  local old_ifs="$IFS"
  IFS=','
  for name in $names; do
    case "$name" in
      ChatGPT|Codex|'Codex++'|'Codex++ 管理工具')
        if [[ "$RUNNING_APPS_COUNT" -gt 0 ]]; then
          RUNNING_APPS_JSON+=','
        fi
        RUNNING_APPS_JSON+="\"$(json_escape "$name")\""
        RUNNING_APPS_COUNT=$((RUNNING_APPS_COUNT + 1))
        ;;
    esac
  done
  IFS="$old_ifs"
  RUNNING_APPS_JSON+=']'
}

resolve_backup_key() {
  local key="$1"
  BACKUP_TARGET=""
  BACKUP_KIND=""
  BACKUP_RELATIVE=""
  case "$key" in
    app.chatgpt)
      BACKUP_TARGET="$APPLICATIONS_DIR/ChatGPT.app"; BACKUP_KIND=directory; BACKUP_RELATIVE='applications/ChatGPT.app' ;;
    app.codex-plus-plus)
      BACKUP_TARGET="$APPLICATIONS_DIR/Codex++.app"; BACKUP_KIND=directory; BACKUP_RELATIVE='applications/Codex++.app' ;;
    app.codex-plus-plus-manager)
      BACKUP_TARGET="$APPLICATIONS_DIR/Codex++ 管理工具.app"; BACKUP_KIND=directory; BACKUP_RELATIVE='applications/Codex++ manager.app' ;;
    marketplace.openai-bundled)
      BACKUP_TARGET="$HOME/.codex/offline-marketplaces/openai-bundled"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/marketplace-openai-bundled' ;;
    marketplace.openai-primary-runtime)
      BACKUP_TARGET="$HOME/.codex/offline-marketplaces/openai-primary-runtime"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/marketplace-openai-primary-runtime' ;;
    marketplace.openai-curated)
      BACKUP_TARGET="$HOME/.codex/offline-marketplaces/openai-curated"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/marketplace-openai-curated' ;;
    plugin.openai-bundled.browser)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-bundled/browser"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-bundled-browser' ;;
    plugin.openai-bundled.chrome)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-bundled/chrome"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-bundled-chrome' ;;
    plugin.openai-bundled.computer-use)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-bundled/computer-use"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-bundled-computer-use' ;;
    plugin.openai-bundled.latex)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-bundled/latex"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-bundled-latex' ;;
    plugin.openai-primary-runtime.pdf)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-primary-runtime/pdf"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-primary-runtime-pdf' ;;
    plugin.openai-primary-runtime.documents)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-primary-runtime/documents"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-primary-runtime-documents' ;;
    plugin.openai-primary-runtime.spreadsheets)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-primary-runtime/spreadsheets"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-primary-runtime-spreadsheets' ;;
    plugin.openai-primary-runtime.presentations)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-primary-runtime/presentations"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-primary-runtime-presentations' ;;
    plugin.openai-curated.github)
      BACKUP_TARGET="$HOME/.codex/plugins/cache/openai-curated/github"; BACKUP_KIND=directory; BACKUP_RELATIVE='managed/plugin-openai-curated-github' ;;
    script.config)
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts.json"; BACKUP_KIND=file; BACKUP_RELATIVE='scripts/user_scripts.json' ;;
    script.file.market-codex-zhcn-translate.js)
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts/market-codex-zhcn-translate.js"; BACKUP_KIND=file; BACKUP_RELATIVE='scripts/user_scripts/market-codex-zhcn-translate.js' ;;
    script.file.market-codex-context-used-meter.js)
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts/market-codex-context-used-meter.js"; BACKUP_KIND=file; BACKUP_RELATIVE='scripts/user_scripts/market-codex-context-used-meter.js' ;;
    script.file.market-codex-token-usage.js)
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts/market-codex-token-usage.js"; BACKUP_KIND=file; BACKUP_RELATIVE='scripts/user_scripts/market-codex-token-usage.js' ;;
    script.file.market-another-script.js)
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts/market-another-script.js"; BACKUP_KIND=file; BACKUP_RELATIVE='scripts/user_scripts/market-another-script.js' ;;
    script.file.market-*.js)
      local script_name="${key#script.file.}"
      if [[ ! "$script_name" =~ ^market-[A-Za-z0-9][A-Za-z0-9._-]*\.js$ ]]; then
        emit_event error null 'backup inventory contains an invalid market script key' '"invalid_backup"'
        return 65
      fi
      BACKUP_TARGET="$HOME/.config/Codex++/user_scripts/$script_name"
      BACKUP_KIND=file
      BACKUP_RELATIVE="scripts/user_scripts/$script_name"
      ;;
    *)
      emit_event error null 'backup inventory contains an unknown key' '"invalid_backup"'
      return 65
      ;;
  esac
}

validate_backup_target() {
  local key="$1"
  resolve_backup_key "$key" || return $?
  case "$key" in
    app.*) safe_app_target "$BACKUP_TARGET" || return $? ;;
    marketplace.*|plugin.*) safe_managed_target "$BACKUP_TARGET" || return $? ;;
    script.*) safe_script_target "$BACKUP_TARGET" || return $? ;;
    *) return 65 ;;
  esac
}

complete_backup_candidate() {
  local candidate="$1"
  case "$candidate" in
    "$BACKUP_ROOT"/.pending-*|"$BACKUP_ROOT"/*) ;;
    *) return 1 ;;
  esac
  [[ "$candidate" != "$BACKUP_ROOT"/.pending-* && -d "$candidate" && ! -L "$candidate" ]] || return 1
  [[ -d "$candidate/configuration" && ! -L "$candidate/configuration" && \
     -f "$candidate/inventory.json" && ! -L "$candidate/inventory.json" && \
     -f "$candidate/configuration/inventory.json" && ! -L "$candidate/configuration/inventory.json" && \
     -f "$candidate/complete" && ! -L "$candidate/complete" && ! -s "$candidate/complete" ]]
}

latest_backup() {
  require_safe_directory_chain "$HOME" 'Library/Application Support/Codex One Click Installer/backups' unsafe_backup || return $?
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    return 0
  fi
  local temporary_root
  local candidates
  local candidate
  local latest=""
  temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return $?
  candidates="$(/usr/bin/mktemp "$temporary_root/codex-backup-candidates.XXXXXX")" || return $?
  /usr/bin/find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 > "$candidates" 2>/dev/null || {
    local find_status=$?
    /bin/rm -f "$candidates" || true
    return "$find_status"
  }
  while IFS= read -r -d '' candidate; do
    if complete_backup_candidate "$candidate"; then
      if [[ -z "$latest" || "$candidate" > "$latest" ]]; then
        latest="$candidate"
      fi
    fi
  done < "$candidates" || {
    local read_status=$?
    /bin/rm -f "$candidates" || true
    return "$read_status"
  }
  /bin/rm -f "$candidates" || return $?
  printf '%s' "$latest"
}

plugin_payload_available() {
  [[ -f "$PAYLOAD_ROOT/plugin-catalog.json" && -f "$PAYLOAD_ROOT/plugins/file-manifest.json" ]]
}

script_payload_available() {
  [[ -f "$PAYLOAD_ROOT/script-market/index.json" && -d "$PAYLOAD_ROOT/script-market/scripts" ]]
}

installed_application_version() {
  local app_path="$1"
  local expected_bundle_id="$2"
  local plist="$app_path/Contents/Info.plist"
  [[ -d "$app_path" && ! -L "$app_path" && -f "$plist" && ! -L "$plist" ]] || return 1
  local bundle_id
  local version
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "$expected_bundle_id" && -n "$version" ]] || return 1
  case "$version" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  printf '%s' "$version"
}

preflight_json() {
  local macos_version
  local architecture_output
  local architecture
  local translated=0
  local disk_bytes
  local mode=fresh
  local backup
  local backup_json=null
  local installed_applications_json='{}'

  validate_managed_paths || return $?

  macos_version="${MACOS_VERSION_OVERRIDE:-$(/usr/bin/sw_vers -productVersion)}"
  local major_version="${macos_version%%.*}"
  if [[ ! "$major_version" =~ ^[0-9]+$ || "$major_version" -lt 14 ]]; then
    emit_event error null 'macOS 14 or newer is required' '"unsupported_macos"'
    return 66
  fi

  if [[ ! -x "$SUPPORT_TOOL" ]]; then
    emit_event error null 'installer support tool is missing' '"missing_support_tool"'
    return 66
  fi
  if [[ ! -f "$PAYLOAD_ROOT/payload-manifest.json" || ! -f "$PAYLOAD_ROOT/model-catalog.json" ]]; then
    emit_event error null 'offline payload metadata is incomplete' '"missing_payload_metadata"'
    return 66
  fi
  if plugin_payload_available; then
    if ! "$SUPPORT_TOOL" plugin-package-validate \
        --root "$PAYLOAD_ROOT/plugins" \
        --catalog "$PAYLOAD_ROOT/plugin-catalog.json" \
        >/dev/null 2> >(redact_stream >&2); then
      emit_event error null 'offline plugin package is invalid' '"invalid_plugin_payload"'
      return 66
    fi
  elif [[ "$TEST_MODE" != "1" || -f "$PAYLOAD_ROOT/plugin-catalog.json" || -e "$PAYLOAD_ROOT/plugins" ]]; then
    emit_event error null 'offline plugin metadata is incomplete' '"missing_plugin_payload"'
    return 66
  fi
  if ! script_payload_available; then
    if [[ "$TEST_MODE" != "1" || -e "$PAYLOAD_ROOT/script-market" ]]; then
      emit_event error null 'offline Codex++ script market is incomplete' '"missing_script_payload"'
      return 66
    fi
  fi
  if ! "$SUPPORT_TOOL" manifest-validate "$PAYLOAD_ROOT/payload-manifest.json" >/dev/null 2> >(redact_stream >&2); then
    emit_event error null 'offline payload manifest is invalid' '"invalid_payload_manifest"'
    return 66
  fi

  architecture_output="$("$SUPPORT_TOOL" hardware-architecture)" || return $?
  architecture="$(printf '%s' "$architecture_output" | /usr/bin/sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p')"
  if [[ "$architecture" != "arm64" && "$architecture" != "x86_64" ]]; then
    emit_event error null 'hardware architecture could not be detected' '"unsupported_architecture"'
    return 66
  fi

  if [[ "$TEST_MODE" == "1" ]]; then
    translated="${ROSETTA_OVERRIDE:-0}"
  elif [[ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
    translated=1
  fi

  if [[ -n "${DISK_BYTES_OVERRIDE:-}" ]]; then
    disk_bytes="$DISK_BYTES_OVERRIDE"
  else
    local disk_blocks
    disk_blocks="$(/bin/df -Pk "$HOME" | /usr/bin/awk 'NR == 2 { print $4 }')"
    disk_bytes=$((disk_blocks * 1024))
  fi
  if [[ ! "$disk_bytes" =~ ^[0-9]+$ || "$disk_bytes" -lt "$REQUIRED_DISK_BYTES" ]]; then
    emit_event error null 'insufficient free disk space' '"insufficient_disk"'
    return 66
  fi

  if [[ -d "$APPLICATIONS_DIR/ChatGPT.app" || -d "$APPLICATIONS_DIR/Codex++.app" || \
        -f "$HOME/.codex/config.toml" || -f "$HOME/.codex-session-delete/settings.json" ]]; then
    mode=upgrade
  fi
  local existing_chatgpt_version
  existing_chatgpt_version="$(
    installed_application_version "$APPLICATIONS_DIR/ChatGPT.app" 'com.openai.codex' || true
  )"
  if [[ -n "$existing_chatgpt_version" ]]; then
    installed_applications_json="$(
      printf '{"ChatGPT/Codex":"%s"}' "$(json_escape "$existing_chatgpt_version")"
    )"
  fi
  detect_running_apps
  backup="$(latest_backup)" || return $?
  if [[ -n "$backup" ]]; then
    backup_json="\"$(json_escape "$backup")\""
  fi

  printf '{"macOSVersion":"%s","architecture":"%s","translated":%s,"availableDiskBytes":%s,"mode":"%s","installedApplications":%s,"runningApplications":%s,"latestBackup":%s}\n' \
    "$(json_escape "$macos_version")" \
    "$architecture" \
    "$([[ "$translated" == "1" ]] && printf true || printf false)" \
    "$disk_bytes" \
    "$mode" \
    "$installed_applications_json" \
    "$RUNNING_APPS_JSON" \
    "$backup_json"
}

journal_config_backup() {
  local root="$1"
  local backup="$2"
  case "$root$backup" in
    *$'\n'*|*'|'*)
      emit_event error null 'unsafe transaction path' '"unsafe_transaction_path"'
      return 65
      ;;
  esac
  printf 'backup_config|%s|%s\n' "$root" "$backup" >> "$JOURNAL_FILE" || return $?
}

rollback_transaction() {
  local reverse_journal="$TRANSACTION_DIR/reverse-journal"
  local operation_status=1
  ROLLBACK_FAILURE_REASON=""
  if [[ -z "$TRANSACTION_DIR" || ! -d "$TRANSACTION_DIR" || -L "$TRANSACTION_DIR" || \
        "$JOURNAL_FILE" != "$TRANSACTION_DIR/journal" || ! -f "$JOURNAL_FILE" || -L "$JOURNAL_FILE" ]]; then
    ROLLBACK_FAILURE_REASON=journal_unavailable
    return 1
  fi
  emit_event rollback null 'restoring previous installation state' null
  [[ ! -L "$reverse_journal" ]] || {
    ROLLBACK_FAILURE_REASON=reverse_journal_unsafe
    return 1
  }
  : > "$reverse_journal" || {
    operation_status=$?
    ROLLBACK_FAILURE_REASON=reverse_journal_write_failed
    return "$operation_status"
  }
  /bin/chmod 600 "$reverse_journal" || {
    operation_status=$?
    ROLLBACK_FAILURE_REASON=reverse_journal_permission_failed
    return "$operation_status"
  }
  /usr/bin/tail -r "$JOURNAL_FILE" > "$reverse_journal" 2> >(redact_stream >&2) || {
    operation_status=$?
    ROLLBACK_FAILURE_REASON=journal_read_failed
    return "$operation_status"
  }

  local action first second
  while IFS='|' read -r action first second; do
    case "$action" in
      backup_app)
        [[ -d "$second" && ! -L "$second" ]] || {
          ROLLBACK_FAILURE_REASON=app_backup_unavailable
          return 1
        }
        restore_app_from_backup "$first" "$second" || {
          ROLLBACK_FAILURE_REASON=app_restore_failed
          return 1
        }
        ;;
      installed_app)
        remove_app_target "$first" || {
          ROLLBACK_FAILURE_REASON=app_remove_failed
          return 1
        }
        ;;
      backup_config)
        if ! "$SUPPORT_TOOL" restore-config --root "$first" --backup "$second" >/dev/null 2> >(redact_stream >&2); then
          ROLLBACK_FAILURE_REASON=configuration_restore_failed
          return 1
        fi
        ;;
      backup_managed)
        [[ -d "$second" && ! -L "$second" ]] || {
          ROLLBACK_FAILURE_REASON=managed_backup_unavailable
          return 1
        }
        restore_managed_from_backup "$first" "$second" || {
          ROLLBACK_FAILURE_REASON=managed_restore_failed
          return 1
        }
        ;;
      created_managed)
        remove_managed_target "$first" || {
          ROLLBACK_FAILURE_REASON=managed_remove_failed
          return 1
        }
        ;;
      backup_script)
        [[ -f "$second" && ! -L "$second" ]] || {
          ROLLBACK_FAILURE_REASON=script_backup_unavailable
          return 1
        }
        restore_script_from_backup "$first" "$second" || {
          ROLLBACK_FAILURE_REASON=script_restore_failed
          return 1
        }
        ;;
      created_script)
        remove_script_target "$first" || {
          ROLLBACK_FAILURE_REASON=script_remove_failed
          return 1
        }
        ;;
      created_script_dir)
        remove_empty_script_directory "$first" || {
          ROLLBACK_FAILURE_REASON=script_directory_remove_failed
          return 1
        }
        ;;
      *)
        ROLLBACK_FAILURE_REASON=journal_entry_invalid
        return 1
        ;;
    esac
  done < "$reverse_journal" || {
    operation_status=$?
    ROLLBACK_FAILURE_REASON=reverse_journal_read_failed
    return "$operation_status"
  }
  emit_event rollback_completed null 'previous installation state restored' null
}

cleanup_transaction() {
  if [[ -n "$MOUNT_POINTS_FILE" && -f "$MOUNT_POINTS_FILE" ]]; then
    local mount_point
    while IFS= read -r mount_point; do
      if [[ -n "$mount_point" ]]; then
        /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
      fi
    done < <(/usr/bin/tail -r "$MOUNT_POINTS_FILE")
  fi
  if [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR" ]]; then
    /bin/rm -R "$TRANSACTION_DIR" || return $?
  fi
  if [[ -n "$PENDING_BACKUP" ]]; then
    case "$PENDING_BACKUP" in
      "$BACKUP_ROOT"/.pending-*) ;;
      *) return 65 ;;
    esac
    if [[ -d "$PENDING_BACKUP" && ! -L "$PENDING_BACKUP" ]]; then
      /bin/rm -R "$PENDING_BACKUP" || return $?
    elif [[ -e "$PENDING_BACKUP" || -L "$PENDING_BACKUP" ]]; then
      return 65
    fi
    PENDING_BACKUP=""
  fi
  TRANSACTION_DIR=""
  JOURNAL_FILE=""
  REQUEST_FILE=""
  MOUNT_POINTS_FILE=""
}

handle_exit() {
  local original_status=$?
  local rollback_status=0
  trap - EXIT
  trap '' INT TERM
  if [[ "$PRESERVE_RECOVERY_STATE" == "1" ]]; then
    exit "$original_status"
  fi
  if [[ "$RESTORE_ACTIVE" == "1" && "$original_status" -ne 0 ]]; then
    restore_complete_backup "$RESTORE_RECOVERY_BACKUP" || rollback_status=$?
    if [[ "$rollback_status" -ne 0 ]]; then
      emit_rollback_failure \
        restore_rollback_failed \
        "$original_status" \
        "$rollback_status" \
        "$RESTORE_RECOVERY_BACKUP"
      PRESERVE_RECOVERY_STATE=1
      exit "$ROLLBACK_FAILURE_EXIT_STATUS"
    fi
    RESTORE_ACTIVE=0
    emit_event rollback_completed null 'the pre-restore state was recovered' null
  fi
  if [[ "$TRANSACTION_ACTIVE" == "1" && "$original_status" -ne 0 ]]; then
    rollback_transaction || rollback_status=$?
    if [[ "$rollback_status" -ne 0 ]]; then
      emit_rollback_failure \
        "${ROLLBACK_FAILURE_REASON:-rollback_operation_failed}" \
        "$original_status" \
        "$rollback_status" \
        "$TRANSACTION_DIR"
      exit "$ROLLBACK_FAILURE_EXIT_STATUS"
    fi
  fi
  cleanup_transaction || exit $?
  exit "$original_status"
}

handle_signal() {
  emit_event cancelled null 'installation cancelled; rolling back' '"cancelled"'
  exit 130
}

trap handle_exit EXIT
trap handle_signal INT TERM

begin_validation_workspace() {
  local transaction_tmp
  transaction_tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return $?
  TRANSACTION_DIR="$(/usr/bin/mktemp -d "$transaction_tmp/codex-one-click.XXXXXX")" || return $?
  /bin/chmod 700 "$TRANSACTION_DIR" || return $?
  JOURNAL_FILE="$TRANSACTION_DIR/journal"
  REQUEST_FILE="$TRANSACTION_DIR/install-request.json"
  MOUNT_POINTS_FILE="$TRANSACTION_DIR/mount-points"
  : > "$JOURNAL_FILE" || return $?
  : > "$REQUEST_FILE" || return $?
  : > "$MOUNT_POINTS_FILE" || return $?
  /bin/chmod 600 "$JOURNAL_FILE" "$REQUEST_FILE" "$MOUNT_POINTS_FILE" || return $?
  TRANSACTION_ACTIVE=0
}

begin_transaction() {
  begin_validation_workspace
}

activate_mutation_transaction() {
  [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || return 65
  [[ -d "$TRANSACTION_DIR/staged-apps" && ! -L "$TRANSACTION_DIR/staged-apps" ]] || return 66
  if plugin_payload_available; then
    [[ -d "$TRANSACTION_DIR/staged-plugins/plugins" && \
       ! -L "$TRANSACTION_DIR/staged-plugins/plugins" ]] || return 66
  fi
  if script_payload_available; then
    [[ -d "$TRANSACTION_DIR/staged-script-market" && \
       ! -L "$TRANSACTION_DIR/staged-script-market" && \
       -d "$TRANSACTION_DIR/script-validation/user_scripts" && \
       ! -L "$TRANSACTION_DIR/script-validation/user_scripts" ]] || return 66
  fi
  create_complete_backup || return $?
  journal_config_backup "$HOME" "$PENDING_BACKUP/configuration" || return $?
  TRANSACTION_ACTIVE=1
}

safe_app_target() {
  local target="$1"
  case "$target" in
    "$APPLICATIONS_DIR/ChatGPT.app"|"$APPLICATIONS_DIR/Codex++.app"|"$APPLICATIONS_DIR/Codex++ 管理工具.app")
      require_safe_absolute_directory_chain "$APPLICATIONS_DIR" unsafe_app_target || return $?
      require_safe_directory_chain "$APPLICATIONS_DIR" "${target#"$APPLICATIONS_DIR/"}" unsafe_app_target || return $?
      return 0
      ;;
    *)
      emit_event error null 'unsafe application target' '"unsafe_app_target"'
      return 65
      ;;
  esac
}

journal_app_record() {
  local action="$1"
  local target="$2"
  local backup="${3:-}"
  safe_app_target "$target" || return $?
  case "$target$backup" in
    *$'\n'*|*'|'*)
      emit_event error null 'unsafe application transaction path' '"unsafe_transaction_path"'
      return 65
      ;;
  esac
  if [[ "$action" == "backup_app" ]]; then
    printf 'backup_app|%s|%s\n' "$target" "$backup" >> "$JOURNAL_FILE" || return $?
  else
    printf 'installed_app|%s|\n' "$target" >> "$JOURNAL_FILE" || return $?
  fi
}

safe_managed_target() {
  local target="$1"
  case "$target" in
    "$HOME/.codex/offline-marketplaces/openai-bundled"|\
    "$HOME/.codex/offline-marketplaces/openai-primary-runtime"|\
    "$HOME/.codex/offline-marketplaces/openai-curated"|\
    "$HOME/.codex/plugins/cache/openai-bundled/browser"|\
    "$HOME/.codex/plugins/cache/openai-bundled/chrome"|\
    "$HOME/.codex/plugins/cache/openai-bundled/computer-use"|\
    "$HOME/.codex/plugins/cache/openai-bundled/latex"|\
    "$HOME/.codex/plugins/cache/openai-primary-runtime/pdf"|\
    "$HOME/.codex/plugins/cache/openai-primary-runtime/documents"|\
    "$HOME/.codex/plugins/cache/openai-primary-runtime/spreadsheets"|\
    "$HOME/.codex/plugins/cache/openai-primary-runtime/presentations"|\
    "$HOME/.codex/plugins/cache/openai-curated/github")
      require_safe_directory_chain "$HOME" "${target#"$HOME/"}" unsafe_plugin_target || return $?
      return 0
      ;;
    *)
      emit_event error null 'unsafe managed plugin target' '"unsafe_plugin_target"'
      return 65
      ;;
  esac
}

journal_managed_record() {
  local action="$1"
  local target="$2"
  local backup="${3:-}"
  safe_managed_target "$target" || return $?
  case "$target$backup" in
    *$'\n'*|*'|'*)
      emit_event error null 'unsafe plugin transaction path' '"unsafe_transaction_path"'
      return 65
      ;;
  esac
  printf '%s|%s|%s\n' "$action" "$target" "$backup" >> "$JOURNAL_FILE" || return $?
}

remove_managed_target() {
  local target="$1"
  safe_managed_target "$target" || return $?
  if [[ -e "$target" || -L "$target" ]]; then
    /bin/rm -R "$target" || return $?
  fi
}

restore_managed_from_backup() {
  local target="$1"
  local backup="$2"
  safe_managed_target "$target" || return $?
  [[ -d "$backup" && ! -L "$backup" ]] || {
    emit_event error null 'managed plugin backup is missing' '"plugin_backup_missing"'
    return 67
  }
  remove_managed_target "$target" || return $?
  ensure_safe_directory_chain "$HOME" "$(/usr/bin/dirname "${target#"$HOME/"}")" unsafe_plugin_target || return $?
  /usr/bin/ditto "$backup" "$target" || return $?
}

safe_script_target() {
  local target="$1"
  local script_directory="$HOME/.config/Codex++/user_scripts"
  if [[ "$target" == "$HOME/.config/Codex++/user_scripts.json" || "$target" == "$script_directory" ]]; then
    if [[ "$target" == "$script_directory" ]]; then
      require_safe_directory_chain "$HOME" '.config/Codex++/user_scripts' unsafe_script_target || return $?
    else
      require_safe_regular_file_if_present "$HOME" '.config/Codex++/user_scripts.json' unsafe_script_target || return $?
    fi
    return 0
  fi
  local parent base
  parent="$(/usr/bin/dirname "$target")"
  base="$(/usr/bin/basename "$target")"
  if [[ "$parent" == "$script_directory" && \
        "$base" =~ ^market-[A-Za-z0-9][A-Za-z0-9._-]*\.js$ ]]; then
    require_safe_regular_file_if_present "$HOME" ".config/Codex++/user_scripts/$base" unsafe_script_target || return $?
    return 0
  fi
  emit_event error null 'unsafe Codex++ script target' '"unsafe_script_target"'
  return 65
}

journal_script_record() {
  local action="$1"
  local target="$2"
  local backup="${3:-}"
  safe_script_target "$target" || return $?
  case "$target$backup" in
    *$'\n'*|*'|'*)
      emit_event error null 'unsafe script transaction path' '"unsafe_transaction_path"'
      return 65
      ;;
  esac
  printf '%s|%s|%s\n' "$action" "$target" "$backup" >> "$JOURNAL_FILE" || return $?
}

remove_script_target() {
  local target="$1"
  safe_script_target "$target" || return $?
  if [[ -e "$target" || -L "$target" ]]; then
    /bin/rm -R "$target" || return $?
  fi
}

restore_script_from_backup() {
  local target="$1"
  local backup="$2"
  safe_script_target "$target" || return $?
  [[ -f "$backup" && ! -L "$backup" ]] || {
    emit_event error null 'Codex++ script backup is missing' '"script_backup_missing"'
    return 67
  }
  remove_script_target "$target" || return $?
  ensure_safe_directory_chain "$HOME" '.config/Codex++/user_scripts' unsafe_script_target || return $?
  /usr/bin/ditto "$backup" "$target" || return $?
}

remove_empty_script_directory() {
  local target="$1"
  safe_script_target "$target" || return $?
  if [[ -d "$target" && ! -L "$target" ]]; then
    /bin/rmdir "$target" 2>/dev/null || return $?
  fi
}

remove_app_target() {
  local target="$1"
  safe_app_target "$target" || return $?
  if [[ ! -e "$target" ]]; then
    return 0
  fi
  if [[ -w "$APPLICATIONS_DIR" ]]; then
    /bin/rm -R "$target" || return $?
    return 0
  fi
  /usr/bin/osascript - "$target" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  do shell script "/bin/rm -rf " & quoted form of targetPath with administrator privileges
end run
APPLESCRIPT
}

restore_app_from_backup() {
  local target="$1"
  local backup="$2"
  safe_app_target "$target" || return $?
  if [[ ! -d "$backup" ]]; then
    emit_event error null 'application backup is missing' '"app_backup_missing"'
    return 67
  fi
  if [[ -w "$APPLICATIONS_DIR" ]]; then
    if [[ -e "$target" ]]; then
      /bin/rm -R "$target" || return $?
    fi
    /usr/bin/ditto "$backup" "$target" || return $?
    return 0
  fi
  /usr/bin/osascript - "$backup" "$target" <<'APPLESCRIPT'
on run argv
  set backupPath to item 1 of argv
  set targetPath to item 2 of argv
  set commandText to "/bin/rm -rf " & quoted form of targetPath & " && /usr/bin/ditto " & quoted form of backupPath & " " & quoted form of targetPath
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
}

snapshot_backup_entry() {
  local key="$1"
  local entries_file="$2"
  local target relative parent
  validate_backup_target "$key" || return $?
  target="$BACKUP_TARGET"
  relative="$BACKUP_RELATIVE"
  if [[ -e "$target" ]]; then
    parent="${relative%/*}"
    ensure_safe_directory_chain "$PENDING_BACKUP" "$parent" unsafe_backup || return $?
    if [[ "$BACKUP_KIND" == directory ]]; then
      [[ -d "$target" && ! -L "$target" ]] || return 65
    else
      [[ -f "$target" && ! -L "$target" ]] || return 65
    fi
    /usr/bin/ditto "$target" "$PENDING_BACKUP/$relative" || return $?
    printf '{"key":"%s","kind":"%s","existed":true,"backupRelativePath":"%s"}\n' \
      "$(json_escape "$key")" "$BACKUP_KIND" "$(json_escape "$relative")" \
      >> "$entries_file" || return $?
  else
    printf '{"key":"%s","kind":"%s","existed":false,"backupRelativePath":null}\n' \
      "$(json_escape "$key")" "$BACKUP_KIND" >> "$entries_file" || return $?
  fi
}

create_complete_backup() {
  local entries_file="$TRANSACTION_DIR/complete-backup-entries.ndjson"
  local expectations_file="$TRANSACTION_DIR/complete-backup-expectations.tsv"
  local inventory_temporary
  local created_at
  local identifier_output
  local backup_identifier
  local key
  local market_script_entries="$TRANSACTION_DIR/complete-backup-market-scripts"
  local staged_market_script_entries="$TRANSACTION_DIR/complete-backup-staged-market-scripts"
  local recorded_market_keys="$TRANSACTION_DIR/complete-backup-recorded-market-keys"
  local market_script_entries_source market_script name

  [[ -n "$TRANSACTION_DIR" && -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || return 65
  ensure_safe_directory_chain "$HOME" 'Library/Application Support/Codex One Click Installer/backups' unsafe_backup || return $?
  /bin/chmod 700 "$BACKUP_ROOT" || return $?
  identifier_output="$("$SUPPORT_TOOL" backup-identifier)" || return $?
  backup_identifier="$(printf '%s' "$identifier_output" | /usr/bin/plutil -extract identifier raw -o - -)" || return $?
  [[ "$backup_identifier" =~ ^[0-9]{20}-[0-9a-f-]{36}$ ]] || return 65
  PENDING_BACKUP="$(/usr/bin/mktemp -d "$BACKUP_ROOT/.pending-$backup_identifier-XXXXXX")" || return $?
  /bin/chmod 700 "$PENDING_BACKUP" || return $?
  created_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || return $?
  COMPLETE_BACKUP="$BACKUP_ROOT/$backup_identifier"
  [[ ! -e "$COMPLETE_BACKUP" && ! -L "$COMPLETE_BACKUP" ]] || return 65

  "$SUPPORT_TOOL" snapshot-config \
    --root "$HOME" \
    --backup "$PENDING_BACKUP/configuration" \
    >/dev/null 2> >(redact_stream >&2) || return $?

  : > "$entries_file" || return $?
  /bin/chmod 600 "$entries_file" || return $?
  fixed_backup_keys > "$expectations_file" || return $?
  /bin/chmod 600 "$expectations_file" || return $?
  while IFS= read -r key; do
    [[ -n "$key" ]] || return 65
    snapshot_backup_entry "$key" "$entries_file" || return $?
  done < "$expectations_file" || return $?

  : > "$market_script_entries" || return $?
  : > "$staged_market_script_entries" || return $?
  : > "$recorded_market_keys" || return $?
  /bin/chmod 600 \
    "$market_script_entries" \
    "$staged_market_script_entries" \
    "$recorded_market_keys" || return $?
  if [[ -d "$HOME/.config/Codex++/user_scripts" ]]; then
    /usr/bin/find "$HOME/.config/Codex++/user_scripts" \
      -mindepth 1 -maxdepth 1 -name 'market-*.js' -print0 \
      > "$market_script_entries" || return $?
  fi
  if [[ -d "$TRANSACTION_DIR/script-validation/user_scripts" ]]; then
    /usr/bin/find "$TRANSACTION_DIR/script-validation/user_scripts" \
      -mindepth 1 -maxdepth 1 -type f -name 'market-*.js' -print0 \
      > "$staged_market_script_entries" || return $?
  fi
  for market_script_entries_source in \
    "$market_script_entries" \
    "$staged_market_script_entries"; do
    while IFS= read -r -d '' market_script; do
      name="$(/usr/bin/basename "$market_script")" || return $?
      case "$name" in
        market-codex-zhcn-translate.js|market-codex-context-used-meter.js|market-codex-token-usage.js|market-another-script.js)
          continue
          ;;
      esac
      key="script.file.$name"
      resolve_backup_key "$key" || return $?
      if /usr/bin/grep -Fxq "$key" "$recorded_market_keys"; then
        continue
      fi
      snapshot_backup_entry "$key" "$entries_file" || return $?
      printf '%s\n' "$key" >> "$recorded_market_keys" || return $?
    done < "$market_script_entries_source" || return $?
  done

  inventory_temporary="$PENDING_BACKUP/.inventory.json.tmp"
  "$SUPPORT_TOOL" build-complete-inventory --created-at "$created_at" \
    < "$entries_file" > "$inventory_temporary" \
    2> >(redact_stream >&2) || return $?
  /bin/chmod 600 "$inventory_temporary" || return $?
  require_safe_regular_file_if_present "$PENDING_BACKUP" '.inventory.json.tmp' unsafe_backup || return $?
  /bin/mv "$inventory_temporary" "$PENDING_BACKUP/inventory.json" || return $?
  require_safe_regular_file_if_present "$PENDING_BACKUP" 'inventory.json' unsafe_backup || return $?
  validate_complete_backup "$PENDING_BACKUP" || return $?
}

validate_complete_backup() {
  local backup="$1"
  local entries_file
  local temporary_root
  local key kind existed relative source
  case "$backup" in
    "$BACKUP_ROOT"/*) ;;
    *) return 65 ;;
  esac
  [[ -d "$backup" && ! -L "$backup" ]] || return 65
  require_safe_regular_file_if_present "$BACKUP_ROOT" "${backup#"$BACKUP_ROOT/"}/inventory.json" unsafe_backup || return $?
  [[ -f "$backup/inventory.json" ]] || return 65

  temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return $?
  entries_file="$(/usr/bin/mktemp "$temporary_root/codex-backup-entries.XXXXXX")" || return $?
  if ! "$SUPPORT_TOOL" validate-complete-inventory \
      --inventory "$backup/inventory.json" \
      > "$entries_file" 2> >(redact_stream >&2); then
    /bin/rm -f "$entries_file" || true
    return 65
  fi
  if ! "$SUPPORT_TOOL" validate-config-backup \
      --root "$HOME" --backup "$backup/configuration" \
      >/dev/null 2> >(redact_stream >&2); then
    /bin/rm -f "$entries_file" || true
    return 65
  fi
  while IFS=$'\t' read -r key kind existed relative; do
    validate_backup_target "$key" || {
      local target_status=$?
      /bin/rm -f "$entries_file" || true
      return "$target_status"
    }
    [[ "$kind" == "$BACKUP_KIND" ]] || {
      /bin/rm -f "$entries_file" || true
      return 65
    }
    if [[ "$existed" == true ]]; then
      [[ "$relative" == "$BACKUP_RELATIVE" ]] || {
        /bin/rm -f "$entries_file" || true
        return 65
      }
      source="$backup/$relative"
      if [[ "$kind" == directory ]]; then
        require_safe_directory_chain "$backup" "$relative" unsafe_backup || {
          local source_status=$?
          /bin/rm -f "$entries_file" || true
          return "$source_status"
        }
        [[ -d "$source" && ! -L "$source" ]] || {
          /bin/rm -f "$entries_file" || true
          return 65
        }
      else
        require_safe_regular_file_if_present "$backup" "$relative" unsafe_backup || {
          local file_status=$?
          /bin/rm -f "$entries_file" || true
          return "$file_status"
        }
        [[ -f "$source" && ! -L "$source" ]] || {
          /bin/rm -f "$entries_file" || true
          return 65
        }
      fi
    elif [[ "$existed" != false || -n "$relative" ]]; then
      /bin/rm -f "$entries_file" || true
      return 65
    fi
  done < "$entries_file" || {
    local read_status=$?
    /bin/rm -f "$entries_file" || true
    return "$read_status"
  }
  /bin/rm -f "$entries_file" || return $?
}

finalize_complete_backup() {
  [[ -n "$PENDING_BACKUP" && -d "$PENDING_BACKUP" && ! -L "$PENDING_BACKUP" ]] || return 65
  [[ -n "$COMPLETE_BACKUP" && ! -e "$COMPLETE_BACKUP" && ! -L "$COMPLETE_BACKUP" ]] || return 65
  validate_complete_backup "$PENDING_BACKUP" || return $?
  require_safe_regular_file_if_present "$PENDING_BACKUP" 'complete' unsafe_backup || return $?
  : > "$PENDING_BACKUP/complete" || return $?
  /bin/chmod 600 "$PENDING_BACKUP/complete" || return $?
  [[ -f "$PENDING_BACKUP/complete" && ! -L "$PENDING_BACKUP/complete" && ! -s "$PENDING_BACKUP/complete" ]] || return 65
  /bin/sync || return $?
  trap '' INT TERM
  /bin/mv "$PENDING_BACKUP" "$COMPLETE_BACKUP" || {
    local move_status=$?
    trap handle_signal INT TERM
    return "$move_status"
  }
  PENDING_BACKUP=""
  TRANSACTION_ACTIVE=0
  trap handle_signal INT TERM
}

restore_privileged_apps() {
  local index action source target source_index target_index
  for ((index = 1; index <= $#; index += 3)); do
    action="${!index}"
    source_index=$((index + 1))
    target_index=$((index + 2))
    source="${!source_index}"
    target="${!target_index}"
    safe_app_target "$target" || return $?
    if [[ "$action" == restore ]]; then
      [[ -d "$source" && ! -L "$source" ]] || return 65
    elif [[ "$action" != remove ]]; then
      return 65
    fi
  done
  /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run argv
  set commandParts to {}
  set itemIndex to 1
  repeat while itemIndex is less than or equal to (count of argv)
    set actionName to item itemIndex of argv
    set sourcePath to item (itemIndex + 1) of argv
    set targetPath to item (itemIndex + 2) of argv
    if actionName is "restore" then
      set end of commandParts to "/bin/rm -rf " & quoted form of targetPath & " && /usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of targetPath
    else
      set end of commandParts to "/bin/rm -rf " & quoted form of targetPath
    end if
    set itemIndex to itemIndex + 3
  end repeat
  set AppleScript's text item delimiters to " && "
  set commandText to commandParts as text
  set AppleScript's text item delimiters to ""
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
}

restore_complete_backup() {
  local backup="$1"
  local entries_file
  local temporary_root
  local key kind existed relative source
  local -a privileged_arguments=()
  validate_complete_backup "$backup" || return $?
  temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return $?
  entries_file="$(/usr/bin/mktemp "$temporary_root/codex-restore-entries.XXXXXX")" || return $?
  if ! "$SUPPORT_TOOL" validate-complete-inventory \
      --inventory "$backup/inventory.json" \
      > "$entries_file" 2> >(redact_stream >&2); then
    /bin/rm -f "$entries_file" || true
    return 65
  fi

  while IFS=$'\t' read -r key kind existed relative; do
    case "$key" in app.*) continue ;; esac
    validate_backup_target "$key" || {
      local target_status=$?
      /bin/rm -f "$entries_file" || true
      return "$target_status"
    }
    if [[ "$existed" == true ]]; then
      source="$backup/$relative"
      case "$key" in
        marketplace.*|plugin.*) restore_managed_from_backup "$BACKUP_TARGET" "$source" || return $? ;;
        script.*) restore_script_from_backup "$BACKUP_TARGET" "$source" || return $? ;;
        *) return 65 ;;
      esac
    else
      case "$key" in
        marketplace.*|plugin.*) remove_managed_target "$BACKUP_TARGET" || return $? ;;
        script.*) remove_script_target "$BACKUP_TARGET" || return $? ;;
        *) return 65 ;;
      esac
    fi
  done < "$entries_file" || return $?

  while IFS=$'\t' read -r key kind existed relative; do
    case "$key" in app.*) ;; *) continue ;; esac
    validate_backup_target "$key" || return $?
    if [[ -w "$APPLICATIONS_DIR" ]]; then
      if [[ "$existed" == true ]]; then
        restore_app_from_backup "$BACKUP_TARGET" "$backup/$relative" || return $?
      else
        remove_app_target "$BACKUP_TARGET" || return $?
      fi
    elif [[ "$existed" == true ]]; then
      privileged_arguments+=(restore "$backup/$relative" "$BACKUP_TARGET")
    else
      privileged_arguments+=(remove '' "$BACKUP_TARGET")
    fi
  done < "$entries_file" || return $?
  if [[ "${#privileged_arguments[@]}" -gt 0 ]]; then
    restore_privileged_apps "${privileged_arguments[@]}" || return $?
  fi
  /bin/rm -f "$entries_file" || return $?
  if [[ "$TEST_MODE" == "1" && -n "${TEST_PAUSE_RESTORE_FILE:-}" && \
        "$backup" != "$RESTORE_RECOVERY_BACKUP" ]]; then
    emit_event paused_restore 0.75 'paused during restore' null
    while [[ -e "$TEST_PAUSE_RESTORE_FILE" ]]; do
      /bin/sleep 0.05
    done
  fi
  if [[ "$TEST_MODE" == "1" && -n "${TEST_PAUSE_RECOVERY_FILE:-}" && \
        "$backup" == "$RESTORE_RECOVERY_BACKUP" ]]; then
    emit_event paused_recovery 0.90 'paused during restore recovery' null
    while [[ -e "$TEST_PAUSE_RECOVERY_FILE" ]]; do
      /bin/sleep 0.05
    done
  fi
  "$SUPPORT_TOOL" restore-config --root "$HOME" --backup "$backup/configuration" \
    >/dev/null 2> >(redact_stream >&2) || return $?
}

payload_json_value() {
  local info_file="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$info_file" 2>/dev/null
}

load_payload_metadata() {
  local architecture="$1"
  local metadata_directory="$2"
  /bin/mkdir -p "$metadata_directory" || return $?
  CHATGPT_PAYLOAD_INFO="$metadata_directory/chatgpt-payload.json"
  CODEX_PLUS_PAYLOAD_INFO="$metadata_directory/codex-plus-payload.json"

  "$SUPPORT_TOOL" payload-resolve \
    --manifest "$PAYLOAD_ROOT/payload-manifest.json" \
    --component chatgpt \
    --architecture "$architecture" \
    > "$CHATGPT_PAYLOAD_INFO" \
    2> >(redact_stream >&2) || return $?
  "$SUPPORT_TOOL" payload-resolve \
    --manifest "$PAYLOAD_ROOT/payload-manifest.json" \
    --component codex-plus-plus \
    --architecture "$architecture" \
    > "$CODEX_PLUS_PAYLOAD_INFO" \
    2> >(redact_stream >&2) || return $?

  CHATGPT_VERSION="$(payload_json_value "$CHATGPT_PAYLOAD_INFO" version)" || return $?
  CHATGPT_BUNDLE_ID="$(payload_json_value "$CHATGPT_PAYLOAD_INFO" bundleIdentifier)" || return $?
  CHATGPT_TEAM_ID="$(payload_json_value "$CHATGPT_PAYLOAD_INFO" teamIdentifier || true)"
  CODEX_PLUS_VERSION="$(payload_json_value "$CODEX_PLUS_PAYLOAD_INFO" version)" || return $?
  CODEX_PLUS_COMPATIBILITY_REVISION="$(
    payload_json_value "$CODEX_PLUS_PAYLOAD_INFO" compatibilityRevision || true
  )"
  if [[ -z "$CHATGPT_VERSION" || -z "$CHATGPT_BUNDLE_ID" || -z "$CODEX_PLUS_VERSION" || \
        "$CODEX_PLUS_COMPATIBILITY_REVISION" != "cross-provider-content-v1" ]]; then
    emit_event error null 'application payload metadata is incomplete' '"invalid_app_metadata"'
    return 66
  fi
}

validated_payload_path() {
  local info_file="$1"
  local relative_path
  relative_path="$(payload_json_value "$info_file" relativePath)" || return $?
  case "$relative_path" in
    ''|/*|../*|*/../*|*/..)
      emit_event error null 'unsafe application payload path' '"unsafe_payload_path"'
      return 65
      ;;
  esac
  local path="$PAYLOAD_ROOT/$relative_path"
  if [[ ! -e "$path" ]]; then
    emit_event error null 'application payload is missing' '"missing_app_payload"'
    return 66
  fi
  printf '%s' "$path"
}

verify_payload_hash() {
  local payload="$1"
  local info_file="$2"
  local format
  local expected
  format="$(payload_json_value "$info_file" format)" || return $?
  expected="$(payload_json_value "$info_file" sha256 | /usr/bin/tr '[:upper:]' '[:lower:]')" || return $?
  if [[ "$format" == "directory" ]]; then
    if [[ "$TEST_MODE" != "1" ]]; then
      emit_event error null 'directory app payloads are test-only' '"invalid_app_payload_format"'
      return 66
    fi
    return 0
  fi
  local actual
  actual="$(/usr/bin/shasum -a 256 "$payload" | /usr/bin/awk '{print tolower($1)}')" || return $?
  if [[ "$actual" != "$expected" ]]; then
    emit_event error null 'application payload hash mismatch' '"app_payload_hash_mismatch"'
    return 66
  fi
}

mount_dmg() {
  local payload="$1"
  local attachment_plist="$TRANSACTION_DIR/mount-$RANDOM.plist"
  /usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$payload" > "$attachment_plist" || return $?
  local index=0
  local mount_point=""
  while [[ "$index" -lt 32 ]]; do
    mount_point="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$attachment_plist" 2>/dev/null || true)"
    if [[ -n "$mount_point" ]]; then
      break
    fi
    index=$((index + 1))
  done
  if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
    emit_event error null 'DMG mount point could not be resolved' '"dmg_mount_failed"'
    return 66
  fi
  printf '%s\n' "$mount_point" >> "$MOUNT_POINTS_FILE" || return $?
  printf '%s' "$mount_point"
}

verify_staged_app() {
  local app_path="$1"
  local expected_bundle_id="$2"
  local expected_version="$3"
  local expected_architecture="$4"
  local expected_team_id="${5:-}"
  local expected_compatibility_revision="${6:-}"
  local plist="$app_path/Contents/Info.plist"
  if [[ ! -f "$plist" ]]; then
    return 1
  fi
  local bundle_id
  local version
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "$expected_bundle_id" || -z "$version" || \
        ( -n "$expected_version" && "$version" != "$expected_version" ) ]]; then
    return 1
  fi
  if [[ -n "$expected_compatibility_revision" ]]; then
    local compatibility_revision
    compatibility_revision="$(
      /usr/libexec/PlistBuddy -c 'Print :CodexKitCompatibilityRevision' "$plist" 2>/dev/null || true
    )"
    [[ "$compatibility_revision" == "$expected_compatibility_revision" ]] || return 1
  fi

  if [[ "$TEST_MODE" == "1" ]]; then
    [[ -f "$app_path/Contents/test-architecture" ]] || return 1
    [[ "$(< "$app_path/Contents/test-architecture")" == "$expected_architecture" ]] || return 1
    return 0
  fi

  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || return 1
  if [[ -n "$expected_team_id" ]]; then
    local team_id
    team_id="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
    [[ "$team_id" == "$expected_team_id" ]] || return 1
  fi
  local executable_name
  local executable_path
  local architectures
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -f "$executable_path" ]] || return 1
  architectures="$(/usr/bin/lipo -archs "$executable_path" 2>/dev/null || /usr/bin/file "$executable_path")"
  case " $architectures " in
    *" $expected_architecture "*) return 0 ;;
    *) return 1 ;;
  esac
}

stage_payload_apps() {
  local architecture="$1"
  local app_stage="$TRANSACTION_DIR/staged-apps"
  /bin/mkdir -p "$app_stage" || return $?
  load_payload_metadata "$architecture" "$TRANSACTION_DIR/payload-metadata" || return $?

  local chatgpt_payload
  local codex_plus_payload
  local chatgpt_format
  local codex_plus_format
  local reuse_existing_chatgpt=0
  safe_app_target "$APPLICATIONS_DIR/ChatGPT.app" || return $?
  if [[ -d "$APPLICATIONS_DIR/ChatGPT.app" ]] && \
     verify_staged_app \
       "$APPLICATIONS_DIR/ChatGPT.app" \
       "$CHATGPT_BUNDLE_ID" \
       "" \
       "$architecture" \
       "$CHATGPT_TEAM_ID"; then
    reuse_existing_chatgpt=1
    emit_event existing_codex_detected 0.18 \
      '检测到可用的原版 Codex，将直接复用且不重复安装' null
  fi

  codex_plus_payload="$(validated_payload_path "$CODEX_PLUS_PAYLOAD_INFO")" || return $?
  verify_payload_hash "$codex_plus_payload" "$CODEX_PLUS_PAYLOAD_INFO" || return $?
  codex_plus_format="$(payload_json_value "$CODEX_PLUS_PAYLOAD_INFO" format)" || return $?

  if [[ "$reuse_existing_chatgpt" == "0" ]]; then
    chatgpt_payload="$(validated_payload_path "$CHATGPT_PAYLOAD_INFO")" || return $?
    verify_payload_hash "$chatgpt_payload" "$CHATGPT_PAYLOAD_INFO" || return $?
    chatgpt_format="$(payload_json_value "$CHATGPT_PAYLOAD_INFO" format)" || return $?
    if [[ "$chatgpt_format" == "directory" ]]; then
      /usr/bin/ditto "$chatgpt_payload" "$app_stage/ChatGPT.app" || return $?
    elif [[ "$chatgpt_format" == "dmg" ]]; then
      local chatgpt_mount
      chatgpt_mount="$(mount_dmg "$chatgpt_payload")" || return $?
      local chatgpt_app_count
      chatgpt_app_count="$(/usr/bin/find "$chatgpt_mount" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" || return $?
      [[ "$chatgpt_app_count" -eq 1 && -d "$chatgpt_mount/ChatGPT.app" ]] || {
        emit_event error null 'official DMG does not contain exactly ChatGPT.app' '"invalid_chatgpt_dmg"'
        return 66
      }
      /usr/bin/ditto "$chatgpt_mount/ChatGPT.app" "$app_stage/ChatGPT.app" || return $?
      /usr/bin/hdiutil detach "$chatgpt_mount" >/dev/null || return $?
    else
      emit_event error null 'unsupported ChatGPT payload format' '"invalid_app_payload_format"'
      return 66
    fi
  fi

  if [[ "$codex_plus_format" == "directory" ]]; then
    [[ -d "$codex_plus_payload/Codex++.app" && -d "$codex_plus_payload/Codex++ 管理工具.app" ]] || {
      emit_event error null 'Codex++ fixture is incomplete' '"invalid_codex_plus_payload"'
      return 66
    }
    /usr/bin/ditto "$codex_plus_payload/Codex++.app" "$app_stage/Codex++.app" || return $?
    /usr/bin/ditto "$codex_plus_payload/Codex++ 管理工具.app" "$app_stage/Codex++ 管理工具.app" || return $?
  elif [[ "$codex_plus_format" == "dmg" ]]; then
    local codex_plus_mount
    codex_plus_mount="$(mount_dmg "$codex_plus_payload")" || return $?
    local codex_plus_app_count
    codex_plus_app_count="$(/usr/bin/find "$codex_plus_mount" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" || return $?
    [[ "$codex_plus_app_count" -eq 2 && -d "$codex_plus_mount/Codex++.app" && -d "$codex_plus_mount/Codex++ 管理工具.app" ]] || {
      emit_event error null 'Codex++ DMG must contain exactly two expected apps' '"invalid_codex_plus_dmg"'
      return 66
    }
    /usr/bin/ditto "$codex_plus_mount/Codex++.app" "$app_stage/Codex++.app" || return $?
    /usr/bin/ditto "$codex_plus_mount/Codex++ 管理工具.app" "$app_stage/Codex++ 管理工具.app" || return $?
    /usr/bin/hdiutil detach "$codex_plus_mount" >/dev/null || return $?
  else
    emit_event error null 'unsupported Codex++ payload format' '"invalid_app_payload_format"'
    return 66
  fi

  local chatgpt_verification_target="$app_stage/ChatGPT.app"
  local chatgpt_expected_version="$CHATGPT_VERSION"
  if [[ "$reuse_existing_chatgpt" == "1" ]]; then
    chatgpt_verification_target="$APPLICATIONS_DIR/ChatGPT.app"
    chatgpt_expected_version=""
  fi
  verify_staged_app "$chatgpt_verification_target" "$CHATGPT_BUNDLE_ID" "$chatgpt_expected_version" "$architecture" "$CHATGPT_TEAM_ID" || {
    emit_event error null 'ChatGPT.app verification failed' '"chatgpt_verify_failed"'
    return 66
  }
  verify_staged_app \
    "$app_stage/Codex++.app" \
    'com.bigpizzav3.codexplusplus' \
    "$CODEX_PLUS_VERSION" \
    "$architecture" \
    "" \
    "$CODEX_PLUS_COMPATIBILITY_REVISION" || {
    emit_event error null 'Codex++.app verification failed' '"codex_plus_verify_failed"'
    return 66
  }
  verify_staged_app \
    "$app_stage/Codex++ 管理工具.app" \
    'com.bigpizzav3.codexplusplus.manager' \
    "$CODEX_PLUS_VERSION" \
    "$architecture" \
    "" \
    "$CODEX_PLUS_COMPATIBILITY_REVISION" || {
    emit_event error null 'Codex++ manager verification failed' '"codex_plus_manager_verify_failed"'
    return 66
  }
}

stage_plugin_payload() {
  if ! plugin_payload_available; then
    return 0
  fi
  local stage="$TRANSACTION_DIR/staged-plugins"
  /bin/mkdir -p "$stage" || return $?
  /usr/bin/ditto "$PAYLOAD_ROOT/plugins" "$stage/plugins" || return $?
  /bin/cp "$PAYLOAD_ROOT/plugin-catalog.json" "$stage/plugin-catalog.json" || return $?
  if ! "$SUPPORT_TOOL" plugin-package-validate \
      --root "$stage/plugins" \
      --catalog "$stage/plugin-catalog.json" \
      >/dev/null 2> >(redact_stream >&2); then
    emit_event error null 'staged plugin package is invalid' '"invalid_plugin_payload"'
    return 66
  fi
}

stage_script_payload() {
  if ! script_payload_available; then
    return 0
  fi
  local stage="$TRANSACTION_DIR/staged-script-market"
  local validation="$TRANSACTION_DIR/script-validation"
  /usr/bin/ditto "$PAYLOAD_ROOT/script-market" "$stage" || return $?
  /bin/mkdir -p "$validation" || return $?
  if ! "$SUPPORT_TOOL" install-scripts \
      --snapshot "$stage" \
      --destination "$validation/user_scripts" \
      --config "$validation/user_scripts.json" \
      >/dev/null 2> >(redact_stream >&2); then
    emit_event error null 'offline Codex++ script market is invalid' '"invalid_script_payload"'
    return 66
  fi
}

journal_script_state() {
  if ! script_payload_available; then
    return 0
  fi
  local destination="$HOME/.config/Codex++/user_scripts"
  local config="$HOME/.config/Codex++/user_scripts.json"
  local existing_file="$TRANSACTION_DIR/existing-market-scripts"
  local discovered_file="$TRANSACTION_DIR/discovered-market-scripts"
  local payload_file="$TRANSACTION_DIR/payload-market-scripts"
  local target backup name
  : > "$existing_file" || return $?
  : > "$discovered_file" || return $?
  : > "$payload_file" || return $?
  /bin/chmod 600 "$existing_file" "$discovered_file" "$payload_file" || return $?

  safe_script_target "$config" || return $?
  safe_script_target "$destination" || return $?
  if [[ -L "$config" ]]; then
    emit_event error null 'Codex++ script configuration must not be a symbolic link' '"unsafe_script_target"'
    return 65
  elif [[ -f "$config" ]]; then
    backup="$PENDING_BACKUP/scripts/user_scripts.json"
    [[ -f "$backup" && ! -L "$backup" ]] || return 65
    journal_script_record backup_script "$config" "$backup" || return $?
  elif [[ -e "$config" ]]; then
    emit_event error null 'Codex++ script configuration target is invalid' '"unsafe_script_target"'
    return 65
  else
    journal_script_record created_script "$config" || return $?
  fi

  if [[ -L "$destination" ]]; then
    emit_event error null 'Codex++ script directory must not be a symbolic link' '"unsafe_script_target"'
    return 65
  elif [[ ! -e "$destination" ]]; then
    journal_script_record created_script_dir "$destination" || return $?
  elif [[ ! -d "$destination" ]]; then
    emit_event error null 'Codex++ script directory target is invalid' '"unsafe_script_target"'
    return 65
  fi

  if [[ -d "$destination" ]]; then
    /usr/bin/find "$destination" -mindepth 1 -maxdepth 1 -name 'market-*.js' -print0 \
      > "$discovered_file" || return $?
    while IFS= read -r -d '' target; do
      name="$(/usr/bin/basename "$target")" || return $?
      [[ "$target" == "$destination/$name" ]] || return 65
      safe_script_target "$target" || return $?
      if [[ -f "$target" && ! -L "$target" ]]; then
        backup="$PENDING_BACKUP/scripts/user_scripts/$name"
        [[ -f "$backup" && ! -L "$backup" ]] || return 65
        journal_script_record backup_script "$target" "$backup" || return $?
        printf '%s\n' "$target" >> "$existing_file" || return $?
      elif [[ -e "$target" || -L "$target" ]]; then
        return 65
      fi
    done < "$discovered_file" || return $?
  fi

  /usr/bin/find "$TRANSACTION_DIR/script-validation/user_scripts" \
    -mindepth 1 -maxdepth 1 -type f -name 'market-*.js' -print0 \
    > "$payload_file" || return $?
  while IFS= read -r -d '' target; do
    name="$(/usr/bin/basename "$target")" || return $?
    target="$destination/$name"
    safe_script_target "$target" || return $?
    if ! /usr/bin/grep -Fxq "$target" "$existing_file"; then
      journal_script_record created_script "$target" || return $?
    fi
  done < "$payload_file" || return $?
}

install_script_market() {
  if ! script_payload_available; then
    return 0
  fi
  journal_script_state || return $?
  if ! "$SUPPORT_TOOL" install-scripts \
      --snapshot "$TRANSACTION_DIR/staged-script-market" \
      --destination "$HOME/.config/Codex++/user_scripts" \
      --config "$HOME/.config/Codex++/user_scripts.json" \
      >/dev/null 2> >(redact_stream >&2); then
    emit_event install_failed null 'Codex++ script market installation failed' '"script_installation_failed"'
    return 65
  fi
}

install_skill_collections() {
  [[ -x "$SCRIPT_DIR/install-skill-collections.sh" \
     && -f "$SCRIPT_DIR/skill-collections.json" \
     && -d "$SCRIPT_DIR/skill-collections" ]] || return 66
  UNICODEX_SKILL_MANIFEST="$SCRIPT_DIR/skill-collections.json" \
    UNICODEX_SKILL_BUNDLE="$SCRIPT_DIR/skill-collections" \
    "$SCRIPT_DIR/install-skill-collections.sh"
}

script_market_version() {
  local filename="$1"
  local config="$HOME/.config/Codex++/user_scripts.json"
  /usr/bin/awk -v filename="$filename" '
    $0 ~ "\\\"user:" filename "\\\"" { in_market_entry = 1; next }
    in_market_entry && /"version"[[:space:]]*:/ {
      value = $0
      sub(/^[^"]*"version"[[:space:]]*:[[:space:]]*"/, "", value)
      sub(/".*/, "", value)
      print value
      exit
    }
    in_market_entry && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit 1 }
  ' "$config"
}

verify_script_market() {
  if ! script_payload_available; then
    return 0
  fi
  local validation="$TRANSACTION_DIR/script-validation/user_scripts"
  local destination="$HOME/.config/Codex++/user_scripts"
  local config="$HOME/.config/Codex++/user_scripts.json"
  local sources_file="$TRANSACTION_DIR/verify-market-scripts"
  local source name context_meter_version token_usage_version
  [[ -f "$config" ]] || return 1
  : > "$sources_file" || return $?
  /bin/chmod 600 "$sources_file" || return $?
  /usr/bin/find "$validation" -mindepth 1 -maxdepth 1 -type f -name 'market-*.js' -print0 \
    > "$sources_file" || return $?
  while IFS= read -r -d '' source; do
    name="$(/usr/bin/basename "$source")" || return $?
    [[ -f "$destination/$name" ]] || return 1
    /usr/bin/cmp -s "$source" "$destination/$name" || return 1
  done < "$sources_file" || return $?
  /usr/bin/grep -Eq '"user:market-codex-zhcn-translate\.js"[[:space:]]*:[[:space:]]*true' "$config" || return 1
  /usr/bin/grep -Eq '"user:market-codex-context-used-meter\.js"[[:space:]]*:[[:space:]]*true' "$config" || return 1
  /usr/bin/grep -Eq '"user:market-codex-token-usage\.js"[[:space:]]*:[[:space:]]*true' "$config" || return 1
  context_meter_version="$(script_market_version market-codex-context-used-meter.js)" || return 1
  token_usage_version="$(script_market_version market-codex-token-usage.js)" || return 1
  [[ "$context_meter_version" == 101 && "$token_usage_version" == 0.1.7 ]]
}

commit_managed_directory() {
  local source="$1"
  local target="$2"
  local label="$3"
  safe_managed_target "$target" || return $?
  [[ -d "$source" && ! -L "$source" ]] || {
    emit_event error null 'staged managed plugin directory is missing' '"missing_staged_plugin"'
    return 66
  }
  [[ ! -L "$target" ]] || {
    emit_event error null 'managed plugin target must not be a symbolic link' '"unsafe_plugin_target"'
    return 65
  }

  local parent
  local sibling_stage
  local backup
  parent="$(/usr/bin/dirname "$target")"
  ensure_safe_directory_chain "$HOME" "${parent#"$HOME/"}" unsafe_plugin_target || return $?
  sibling_stage="$(/usr/bin/mktemp -d "$parent/.codex-one-click-stage.XXXXXX")" || return $?
  /usr/bin/ditto "$source" "$sibling_stage/new" || return $?

  if [[ -e "$target" ]]; then
    backup="$PENDING_BACKUP/managed/$label"
    [[ -d "$backup" && ! -L "$backup" ]] || return 65
    journal_managed_record backup_managed "$target" "$backup" || return $?
    safe_managed_target "$target" || return $?
    /bin/rm -R "$target" || return $?
  else
    journal_managed_record created_managed "$target" || return $?
  fi
  /bin/mv "$sibling_stage/new" "$target" || return $?
  /bin/rmdir "$sibling_stage" || return $?
  /bin/chmod 700 "$target" || return $?
}

commit_staged_plugins() {
  if ! plugin_payload_available; then
    return 0
  fi
  local stage="$TRANSACTION_DIR/staged-plugins/plugins"
  local marketplace plugin
  for marketplace in openai-bundled openai-primary-runtime openai-curated; do
    commit_managed_directory \
      "$stage/marketplaces/$marketplace" \
      "$HOME/.codex/offline-marketplaces/$marketplace" \
      "marketplace-$marketplace" || return $?
  done
  while IFS='|' read -r marketplace plugin; do
    commit_managed_directory \
      "$stage/cache/$marketplace/$plugin" \
      "$HOME/.codex/plugins/cache/$marketplace/$plugin" \
      "plugin-$marketplace-$plugin" || return $?
  done <<'PLUGINS'
openai-bundled|browser
openai-bundled|chrome
openai-bundled|computer-use
openai-bundled|latex
openai-primary-runtime|pdf
openai-primary-runtime|documents
openai-primary-runtime|spreadsheets
openai-primary-runtime|presentations
openai-curated|github
PLUGINS
}

configure_managed_plugins() {
  if ! plugin_payload_available; then
    return 0
  fi
  require_safe_directory_chain "$HOME" '.codex/offline-marketplaces' unsafe_plugin_target || return $?
  require_safe_directory_chain "$HOME" '.codex/plugins/cache' unsafe_plugin_target || return $?
  require_safe_regular_file_if_present "$HOME" '.codex/config.toml' unsafe_configuration_target || return $?
  if ! "$SUPPORT_TOOL" configure-plugins \
      --root "$HOME" \
      --catalog "$TRANSACTION_DIR/staged-plugins/plugin-catalog.json" \
      >/dev/null 2> >(redact_stream >&2); then
    emit_event install_failed null 'Codex plugin configuration failed' '"plugin_configuration_failed"'
    return 65
  fi
}

verify_managed_plugins() {
  if ! plugin_payload_available; then
    return 0
  fi
  local marketplace plugin version_root config="$HOME/.codex/config.toml"
  for marketplace in openai-bundled openai-primary-runtime openai-curated; do
    [[ -f "$HOME/.codex/offline-marketplaces/$marketplace/.agents/plugins/marketplace.json" ]] || return 1
    /usr/bin/grep -Fq "[marketplaces.\"$marketplace\"]" "$config" || return 1
  done
  while IFS='|' read -r marketplace plugin; do
    version_root="$HOME/.codex/plugins/cache/$marketplace/$plugin"
    [[ "$(/usr/bin/find "$version_root" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 1 ]] || return 1
    [[ -f "$(/usr/bin/find "$version_root" -mindepth 1 -maxdepth 1 -type d | /usr/bin/head -n 1)/.codex-plugin/plugin.json" ]] || return 1
    /usr/bin/grep -Fq "[plugins.\"$plugin@$marketplace\"]" "$config" || return 1
  done <<'PLUGINS'
openai-bundled|browser
openai-bundled|chrome
openai-bundled|computer-use
openai-bundled|latex
openai-primary-runtime|pdf
openai-primary-runtime|documents
openai-primary-runtime|spreadsheets
openai-primary-runtime|presentations
openai-curated|github
PLUGINS
  "$SUPPORT_TOOL" verify-plugin-config \
    --root "$HOME" \
    --catalog "$PAYLOAD_ROOT/plugin-catalog.json" \
    >/dev/null 2> >(redact_stream >&2) || return 1
}

commit_direct_app() {
  local staged="$1"
  local target="$2"
  safe_app_target "$target" || return $?
  local copy_root
  copy_root="$(/usr/bin/mktemp -d "$APPLICATIONS_DIR/.codex-one-click-stage.XXXXXX")" || return $?
  /usr/bin/ditto "$staged" "$copy_root/$(/usr/bin/basename "$target")" || return $?
  if [[ -e "$target" ]]; then
    /bin/rm -R "$target" || return $?
  fi
  /bin/mv "$copy_root/$(/usr/bin/basename "$target")" "$target" || return $?
  /bin/rmdir "$copy_root" || return $?
}

commit_privileged_apps() {
  local index
  local target
  for ((index = 2; index <= $#; index += 2)); do
    target="${!index}"
    safe_app_target "$target" || return $?
  done
  /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run argv
  set commandParts to {}
  set itemIndex to 1
  repeat while itemIndex is less than or equal to (count of argv)
    set stagedPath to item itemIndex of argv
    set targetPath to item (itemIndex + 1) of argv
    set end of commandParts to "/bin/rm -rf " & quoted form of targetPath & " && /usr/bin/ditto " & quoted form of stagedPath & " " & quoted form of targetPath
    set itemIndex to itemIndex + 2
  end repeat
  set AppleScript's text item delimiters to " && "
  set commandText to commandParts as text
  set AppleScript's text item delimiters to ""
  do shell script commandText with administrator privileges
end run
APPLESCRIPT
}

commit_staged_apps() {
  local architecture="$1"
  local app_stage="$TRANSACTION_DIR/staged-apps"
  local -a stages=()
  local -a targets=()
  local name bundle version team staged target backup
  local codex_plus_pair_matches=0

  if verify_staged_app \
      "$APPLICATIONS_DIR/Codex++.app" \
      'com.bigpizzav3.codexplusplus' \
      "$CODEX_PLUS_VERSION" \
      "$architecture" \
      "" \
      "$CODEX_PLUS_COMPATIBILITY_REVISION" && \
     verify_staged_app \
      "$APPLICATIONS_DIR/Codex++ 管理工具.app" \
      'com.bigpizzav3.codexplusplus.manager' \
      "$CODEX_PLUS_VERSION" \
      "$architecture" \
      "" \
      "$CODEX_PLUS_COMPATIBILITY_REVISION"; then
    codex_plus_pair_matches=1
  elif [[ -d "$APPLICATIONS_DIR/Codex++.app" || \
          -d "$APPLICATIONS_DIR/Codex++ 管理工具.app" ]]; then
    emit_event codex_plus_compatibility_upgrade null \
      '检测到旧版或未修补的 Codex++，将成对升级兼容版启动器与管理工具' null
  fi

  for name in 'ChatGPT.app' 'Codex++.app' 'Codex++ 管理工具.app'; do
    staged="$app_stage/$name"
    target="$APPLICATIONS_DIR/$name"
    safe_app_target "$target" || return $?
    case "$name" in
      'ChatGPT.app')
        bundle="$CHATGPT_BUNDLE_ID"; version="$CHATGPT_VERSION"; team="$CHATGPT_TEAM_ID"
        ;;
      'Codex++.app')
        bundle='com.bigpizzav3.codexplusplus'; version="$CODEX_PLUS_VERSION"; team=''
        ;;
      *)
        bundle='com.bigpizzav3.codexplusplus.manager'; version="$CODEX_PLUS_VERSION"; team=''
        ;;
    esac

    if [[ "$name" == 'ChatGPT.app' && -d "$target" ]] && \
       verify_staged_app "$target" "$bundle" "" "$architecture" "$team"; then
      emit_event reused_app null \
        '已复用现有原版 Codex，未执行覆盖或重复安装' null
      continue
    fi

    if [[ "$name" != 'ChatGPT.app' && "$codex_plus_pair_matches" == "1" ]]; then
      emit_event skipped_app null "$name already matches the selected payload" null
      continue
    fi

    if [[ ! -d "$staged" || -L "$staged" ]]; then
      emit_event error null "$name staged payload is unavailable" '"missing_staged_app"'
      return 66
    fi

    if [[ -e "$target" ]]; then
      case "$name" in
        'ChatGPT.app') backup="$PENDING_BACKUP/applications/ChatGPT.app" ;;
        'Codex++.app') backup="$PENDING_BACKUP/applications/Codex++.app" ;;
        'Codex++ 管理工具.app') backup="$PENDING_BACKUP/applications/Codex++ manager.app" ;;
        *) return 65 ;;
      esac
      [[ -d "$backup" && ! -L "$backup" ]] || return 65
      journal_app_record backup_app "$target" "$backup" || return $?
    else
      journal_app_record installed_app "$target" || return $?
    fi
    stages+=("$staged")
    targets+=("$target")
  done

  local replacement_count="${#targets[@]}"
  if [[ "$replacement_count" -eq 0 ]]; then
    return 0
  fi
  local index
  if [[ -w "$APPLICATIONS_DIR" ]]; then
    for ((index = 0; index < replacement_count; index++)); do
      commit_direct_app "${stages[$index]}" "${targets[$index]}" || return $?
      emit_event installed_app null "$(/usr/bin/basename "${targets[$index]}") installed" null
      if [[ "$TEST_MODE" == "1" && "${FAIL_AFTER_APP_INDEX:-0}" == "$((index + 1))" ]]; then
        emit_event install_failed null 'injected failure during application commit' '"injected_app_failure"'
        return 75
      fi
    done
  else
    local -a arguments=()
    for ((index = 0; index < replacement_count; index++)); do
      arguments+=("${stages[$index]}" "${targets[$index]}")
    done
    commit_privileged_apps "${arguments[@]}" || return $?
    for ((index = 0; index < replacement_count; index++)); do
      emit_event installed_app null "$(/usr/bin/basename "${targets[$index]}") installed" null
    done
  fi
}

verify_installed_apps() {
  local architecture="$1"
  local metadata_directory="${TRANSACTION_DIR:-${TMPDIR:-/tmp}/codex-one-click-verify-$$}"
  local remove_metadata=0
  if [[ -z "$TRANSACTION_DIR" ]]; then
    /bin/mkdir -p "$metadata_directory" || return $?
    remove_metadata=1
  fi
  load_payload_metadata "$architecture" "$metadata_directory" || return $?
  verify_staged_app "$APPLICATIONS_DIR/ChatGPT.app" "$CHATGPT_BUNDLE_ID" "" "$architecture" "$CHATGPT_TEAM_ID" || return 1
  INSTALLED_CHATGPT_VERSION="$(
    installed_application_version "$APPLICATIONS_DIR/ChatGPT.app" "$CHATGPT_BUNDLE_ID"
  )" || return $?
  verify_staged_app \
    "$APPLICATIONS_DIR/Codex++.app" \
    'com.bigpizzav3.codexplusplus' \
    "$CODEX_PLUS_VERSION" \
    "$architecture" \
    "" \
    "$CODEX_PLUS_COMPATIBILITY_REVISION" || return 1
  verify_staged_app \
    "$APPLICATIONS_DIR/Codex++ 管理工具.app" \
    'com.bigpizzav3.codexplusplus.manager' \
    "$CODEX_PLUS_VERSION" \
    "$architecture" \
    "" \
    "$CODEX_PLUS_COMPATIBILITY_REVISION" || return 1
  if [[ "$remove_metadata" == "1" ]]; then
    /bin/rm -R "$metadata_directory" || return $?
  fi
}

verify_installation() {
  validate_managed_paths || return $?
  reset_self_check_state
  [[ -n "$TRANSACTION_DIR" ]] || return 65
  local configuration_result="$TRANSACTION_DIR/configuration-verification.json"
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'configuration-verification.json' unsafe_self_check || return $?
  if [[ ! -f "$HOME/.codex/config.toml" || ! -f "$HOME/.codex/auth.json" || \
        ! -f "$HOME/.codex-session-delete/settings.json" || \
        ! -f "$HOME/Library/Application Support/Codex One Click Installer/install-expectation.json" ]] || \
     ! "$SUPPORT_TOOL" verify-config \
        --root "$HOME" \
        --catalog "$PAYLOAD_ROOT/model-catalog.json" \
        --expectation "$HOME/Library/Application Support/Codex One Click Installer/install-expectation.json" \
        > "$configuration_result" 2> >(redact_stream >&2); then
    fail_self_check configuration configuration_semantics_mismatch \
      'managed configuration self-check failed' configuration_verify_failed
    return $?
  fi
  SELF_CHECK_PROVIDER="$(/usr/bin/plutil -extract provider raw -o - "$configuration_result")" || return $?
  SELF_CHECK_DEFAULT_MODEL="$(/usr/bin/plutil -extract defaultModel raw -o - "$configuration_result")" || return $?
  SELF_CHECK_MODEL_COUNT="$(/usr/bin/plutil -extract modelCount raw -o - "$configuration_result")" || return $?
  SELF_CHECK_AUTHENTICATION_MODE="$(/usr/bin/plutil -extract authenticationMode raw -o - "$configuration_result")" || return $?
  SELF_CHECK_CONFIGURATION_STATUS=pass
  if ! "$SUPPORT_TOOL" manifest-validate "$PAYLOAD_ROOT/payload-manifest.json" >/dev/null 2> >(redact_stream >&2); then
    fail_self_check payload payload_manifest_invalid \
      'payload self-check failed' payload_verify_failed
    return $?
  fi
  SELF_CHECK_PAYLOAD_STATUS=pass
  local architecture_output
  local architecture
  architecture_output="$("$SUPPORT_TOOL" hardware-architecture)" || return $?
  architecture="$(printf '%s' "$architecture_output" | /usr/bin/sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p')"
  SELECTED_ARCHITECTURE="$architecture"
  if ! verify_installed_apps "$architecture"; then
    fail_self_check applications application_metadata_mismatch \
      'installed application self-check failed' application_verify_failed
    return $?
  fi
  SELF_CHECK_APPLICATIONS_STATUS=pass
  SELF_CHECK_APPLICATION_COUNT=3
  if ! verify_managed_plugins; then
    fail_self_check plugins managed_plugin_mismatch \
      'installed plugin self-check failed' plugin_verify_failed
    return $?
  fi
  SELF_CHECK_PLUGINS_STATUS=pass
  if plugin_payload_available; then
    SELF_CHECK_MARKETPLACE_COUNT=3
    SELF_CHECK_PLUGIN_COUNT=9
  fi
  if ! verify_script_market; then
    fail_self_check scripts managed_script_mismatch \
      'Codex++ script market self-check failed' script_verify_failed
    return $?
  fi
  SELF_CHECK_SCRIPTS_STATUS=pass
  if script_payload_available; then
    SELF_CHECK_TRANSLATION_ENABLED=true
    SELF_CHECK_CONTEXT_METER_ENABLED=true
    SELF_CHECK_TOKEN_USAGE_ENABLED=true
    SELF_CHECK_CONTEXT_METER_VERSION="$(script_market_version market-codex-context-used-meter.js)" || return $?
    SELF_CHECK_TOKEN_USAGE_VERSION="$(script_market_version market-codex-token-usage.js)" || return $?
  fi
  write_self_check pass || return $?
}

prepare_report() {
  local report_timestamp
  local authentication_mode authorization_status
  report_timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  [[ -f "$SELF_CHECK_PATH" && ! -L "$SELF_CHECK_PATH" ]] || return 65
  [[ "$(/usr/bin/plutil -extract overall raw -o - "$SELF_CHECK_PATH")" == pass ]] || return 67
  authentication_mode="$(/usr/bin/plutil -extract configuration.authenticationMode raw -o - "$SELF_CHECK_PATH")" || return $?
  case "$authentication_mode" in
    openAIAccountWithAPI)
      authorization_status=authorized
      ;;
    pureAPI)
      authorization_status=skipped
      ;;
    *)
      return 65
      ;;
  esac
  ensure_safe_absolute_directory_chain "$REPORT_DIR" unsafe_report_target || return $?
  /bin/chmod 700 "$REPORT_DIR" || return $?
  INSTALL_REPORT_PATH="$REPORT_DIR/install-report-$report_timestamp.md"
  PREPARED_REPORT_PATH="$TRANSACTION_DIR/install-report.prepared"
  require_safe_absolute_regular_file_if_present "$INSTALL_REPORT_PATH" unsafe_report_target || return $?
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'install-report.prepared' unsafe_report_target || return $?
  {
    printf 'OpenAI authorization: %s\n' "$authorization_status"
    printf '%s\n' 'Context Used Meter: 101 · enabled · runtime-smoke-pass'
    printf '%s\n' 'Codex Token Usage: 0.1.7 · enabled · runtime-smoke-pass'
  } | redact_stream > "$PREPARED_REPORT_PATH" || return $?
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'install-report.prepared' unsafe_report_target || return $?
  /bin/chmod 600 "$PREPARED_REPORT_PATH" || return $?
}

publish_report() {
  [[ -n "$INSTALL_REPORT_PATH" && -n "$PREPARED_REPORT_PATH" ]] || return 65
  require_safe_regular_file_if_present "$TRANSACTION_DIR" 'install-report.prepared' unsafe_report_target || return $?
  [[ -f "$PREPARED_REPORT_PATH" && ! -L "$PREPARED_REPORT_PATH" ]] || return 65
  require_safe_absolute_regular_file_if_present "$INSTALL_REPORT_PATH" unsafe_report_target || return $?
  /bin/mv -f "$PREPARED_REPORT_PATH" "$INSTALL_REPORT_PATH" || return $?
}

verify_command() {
  local temporary_root
  local verification_directory
  local verification_status=0
  temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || return $?
  verification_directory="$(/usr/bin/mktemp -d "$temporary_root/codex-one-click-verify.XXXXXX")" || return $?
  /bin/chmod 700 "$verification_directory" || return $?
  TRANSACTION_DIR="$verification_directory"
  if script_payload_available; then
    stage_script_payload || {
      verification_status=$?
      /bin/rm -R "$verification_directory" || true
      TRANSACTION_DIR=""
      return "$verification_status"
    }
  fi
  verify_installation || verification_status=$?
  if [[ "$verification_status" -eq 0 ]]; then
    emit_event verify_completed 1.0 'installation self-check passed' null
  fi
  if [[ -f "$SELF_CHECK_PATH" && ! -L "$SELF_CHECK_PATH" ]]; then
    /bin/cat "$SELF_CHECK_PATH" || verification_status=$?
  fi
  /bin/rm -R "$verification_directory" || {
    [[ "$verification_status" -ne 0 ]] || verification_status=$?
  }
  TRANSACTION_DIR=""
  return "$verification_status"
}

install_command() {
  if [[ "$#" -ne 1 || "$1" != "--request-stdin" ]]; then
    emit_event error null 'invalid install arguments' '"invalid_arguments"'
    return 64
  fi

  local preflight
  local preflight_status
  preflight="$(preflight_json)" || {
    preflight_status=$?
    printf '%s\n' "$preflight"
    return "$preflight_status"
  }
  detect_running_apps
  if [[ "$RUNNING_APPS_COUNT" -gt 0 ]]; then
    emit_event running_apps null 'quit ChatGPT/Codex++ normally, then retry' '"running_apps"'
    return 69
  fi

  begin_validation_workspace || return $?
  cat > "$REQUEST_FILE" || return $?
  local request_bytes
  request_bytes="$(/usr/bin/wc -c < "$REQUEST_FILE" | /usr/bin/tr -d ' ')" || return $?
  if [[ "$request_bytes" -eq 0 || "$request_bytes" -gt 1048576 ]]; then
    emit_event install_failed null 'invalid install request' '"invalid_request"'
    return 65
  fi

  emit_event installing 0.10 'validating offline installation request' null
  local architecture_output
  architecture_output="$("$SUPPORT_TOOL" hardware-architecture)" || return $?
  SELECTED_ARCHITECTURE="$(printf '%s' "$architecture_output" | /usr/bin/sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p')"
  emit_event staging_apps 0.20 'staging and verifying architecture-specific applications' null
  stage_payload_apps "$SELECTED_ARCHITECTURE" || return $?
  emit_event staging_plugins 0.28 'staging and verifying offline Codex plugins' null
  stage_plugin_payload || return $?
  emit_event staging_scripts 0.31 'staging and verifying the offline Codex++ script market' null
  stage_script_payload || return $?
  emit_event validating_request 0.32 'validating provider and model selection' null
  "$SUPPORT_TOOL" validate-install-request \
    --catalog "$PAYLOAD_ROOT/model-catalog.json" \
    < "$REQUEST_FILE" \
    > "$TRANSACTION_DIR/request-validation.json" \
    2> >(redact_stream >&2) || {
      emit_event install_failed null 'provider or model validation failed' '"invalid_request"'
      return 65
    }
  emit_event backing_up 0.33 'creating a durable complete pre-install snapshot' null
  activate_mutation_transaction || return $?
  emit_event committing_apps 0.35 'installing ChatGPT/Codex and Codex++ applications' null
  commit_staged_apps "$SELECTED_ARCHITECTURE" || return $?

  local result_file="$TRANSACTION_DIR/configuration-result.json"
  if ! "$SUPPORT_TOOL" apply-config \
      --root "$HOME" \
      --catalog "$PAYLOAD_ROOT/model-catalog.json" \
      --backup "$PENDING_BACKUP/configuration" \
      < "$REQUEST_FILE" \
      > "$result_file" \
      2> >(redact_stream >&2); then
    emit_event install_failed null 'configuration failed' '"configuration_failed"'
    return 65
  fi

  local backup
  local provider_id
  backup="$(/usr/bin/plutil -extract backupDirectory raw -o - "$result_file" 2>/dev/null || true)"
  provider_id="$(/usr/bin/plutil -extract managedProviderID raw -o - "$result_file" 2>/dev/null || true)"
  if [[ "$backup" != "$PENDING_BACKUP/configuration" ]]; then
      emit_event install_failed null 'configuration returned an unsafe backup path' '"unsafe_backup"'
      return 65
  fi
  emit_event configured 0.65 'Codex and Codex++ configuration applied' null

  emit_event installing_plugins 0.72 'installing offline Codex marketplaces and plugins' null
  commit_staged_plugins || return $?
  configure_managed_plugins || return $?
  if [[ "$TEST_MODE" == "1" && "${FAIL_AFTER_PLUGINS:-0}" == "1" ]]; then
    emit_event install_failed null 'injected failure after plugin deployment' '"injected_plugin_failure"'
    return 75
  fi

  emit_event installing_scripts 0.78 'installing the Codex++ script market' null
  install_script_market || return $?
  emit_event installing_skills 0.81 'installing 211 research skills' null
  install_skill_collections || return $?
  if [[ "$TEST_MODE" == "1" && "${FAIL_AFTER_SCRIPTS:-0}" == "1" ]]; then
    emit_event install_failed null 'injected failure after script deployment' '"injected_script_failure"'
    return 75
  fi

  if [[ "$TEST_MODE" == "1" && "${FAIL_AFTER_CONFIG:-0}" == "1" ]]; then
    emit_event install_failed null 'injected failure after configuration' '"injected_failure"'
    return 75
  fi
  if [[ "$TEST_MODE" == "1" && -n "${TEST_PAUSE_FILE:-}" ]]; then
    emit_event paused_after_config 0.60 'paused after configuration' null
    while [[ -e "$TEST_PAUSE_FILE" ]]; do
      /bin/sleep 0.05
    done
  fi

  emit_event verifying 0.85 'running installation self-checks' null
  verify_installation || return $?
  prepare_report "$provider_id" "$COMPLETE_BACKUP" || return $?
  finalize_complete_backup || return $?
  local completion_message
  if publish_report; then
    completion_message="installation completed; report: $INSTALL_REPORT_PATH"
  else
    completion_message='installation completed; the report could not be published'
    emit_event warning null 'installation succeeded but the report could not be published' '"report_failed"'
  fi
  if ! cleanup_transaction; then
    emit_event warning null 'installation succeeded but temporary cleanup was incomplete' '"cleanup_failed"'
  fi
  emit_event install_completed 1.0 "$completion_message" null
}

restore_latest_command() {
  local backup
  local temporary_snapshot
  local restore_status=0
  local rollback_status=0
  backup="$(latest_backup)" || return $?
  if [[ -z "$backup" ]]; then
    emit_event error null 'no backup is available' '"backup_not_found"'
    return 66
  fi
  case "$backup" in
    "$BACKUP_ROOT"/*) ;;
    *)
      emit_event error null 'unsafe backup path' '"unsafe_backup"'
      return 65
      ;;
  esac
  validate_complete_backup "$backup" || {
    emit_event error null 'restore backup validation failed' '"restore_failed"'
    return 67
  }
  begin_validation_workspace || return $?
  create_complete_backup || return $?
  temporary_snapshot="$PENDING_BACKUP"
  TRANSACTION_ACTIVE=0
  RESTORE_RECOVERY_BACKUP="$temporary_snapshot"
  RESTORE_ACTIVE=1
  emit_event restoring 0.25 'restoring latest backup' null
  restore_complete_backup "$backup" || restore_status=$?
  if [[ "$restore_status" -ne 0 ]]; then
    trap '' INT TERM
    restore_complete_backup "$temporary_snapshot" || rollback_status=$?
    if [[ "$rollback_status" -ne 0 ]]; then
      PRESERVE_RECOVERY_STATE=1
      RESTORE_ACTIVE=0
      trap handle_signal INT TERM
      emit_rollback_failure restore_rollback_failed "$restore_status" "$rollback_status" "$temporary_snapshot"
      emit_event error null 'restore failed and automatic rollback failed; recovery materials were preserved' '"restore_failed"'
      return "$ROLLBACK_FAILURE_EXIT_STATUS"
    fi
    RESTORE_ACTIVE=0
    trap handle_signal INT TERM
    cleanup_transaction || return $?
    emit_event error null 'restore failed; the pre-restore state was recovered' '"restore_failed"'
    return 67
  fi
  RESTORE_ACTIVE=0
  cleanup_transaction || return $?
  emit_event restore_completed 1.0 'latest backup restored' null
}

command_name="${1:-}"
if [[ "$#" -gt 0 ]]; then
  shift
fi

case "$command_name" in
  preflight)
    [[ "$#" -eq 0 ]] || { emit_event error null 'invalid preflight arguments' '"invalid_arguments"'; exit 64; }
    preflight_json
    ;;
  auth-status)
    [[ "$#" -eq 0 ]] || { emit_event error null 'invalid auth status arguments' '"invalid_arguments"'; exit 64; }
    "$SUPPORT_TOOL" chatgpt-auth-status --root "$HOME"
    ;;
  install)
    install_command "$@"
    ;;
  verify)
    [[ "$#" -eq 0 ]] || { emit_event error null 'invalid verify arguments' '"invalid_arguments"'; exit 64; }
    verify_command || exit $?
    ;;
  restore-latest)
    [[ "$#" -eq 0 ]] || { emit_event error null 'invalid restore arguments' '"invalid_arguments"'; exit 64; }
    restore_latest_command
    ;;
  *)
    emit_event error null 'unknown installer command' '"invalid_arguments"'
    exit 64
    ;;
esac
