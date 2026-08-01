#!/usr/bin/env bash
set -euo pipefail
umask 077

deepseek_catalog_key="${DEEPSEEK_CATALOG_KEY-}"
kimi_open_catalog_key="${KIMI_OPEN_CATALOG_KEY-}"
unset DEEPSEEK_CATALOG_KEY KIMI_OPEN_CATALOG_KEY

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_MODE="${TEST_MODE:-0}"
RESOURCE_DIR="${RESOURCE_DIR_OVERRIDE:-$ROOT/Resources}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT/vendor/offline-payloads}"
BUILDER_HOME="${BUILDER_HOME:-${HOME:?}}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
APP_INSPECT_BIN="${APP_INSPECT_BIN:-}"
GENERATED_AT="${GENERATED_AT_OVERRIDE:-$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')}"
SOURCES_FILE="$RESOURCE_DIR/upstream-sources.json"
PLUGIN_CATALOG="$RESOURCE_DIR/plugin-catalog.json"
MODEL_CATALOG="$RESOURCE_DIR/model-catalog.json"
SCRIPT_MARKET_OVERRIDES="$RESOURCE_DIR/script-market-overrides.json"
USE_CACHED_MODEL_CATALOG=0
CODEX_PLUS_TAG=''
PREPARE_CODEX_PLUS_COMPATIBILITY_BUILD=0
SUPPORT_TOOL_PATH="${SUPPORT_TOOL:-}"
PAYLOAD_FIND_BIN="${PAYLOAD_FIND_BIN:-/usr/bin/find}"
TEMP_ROOT=""
MOUNT_POINTS_FILE=""
STAGED_FILES=("")

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$MOUNT_POINTS_FILE" && -f "$MOUNT_POINTS_FILE" ]]; then
    while IFS= read -r mount_point; do
      [[ -n "$mount_point" ]] && /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    done < <(/usr/bin/tail -r "$MOUNT_POINTS_FILE")
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    /bin/rm -R "$TEMP_ROOT"
  fi
  local staged_file
  for staged_file in "${STAGED_FILES[@]}"; do
    [[ -n "$staged_file" ]] || continue
    if [[ -e "$staged_file" || -L "$staged_file" ]]; then
      /bin/rm -f "$staged_file"
    fi
  done
  exit "$status"
}
trap cleanup EXIT

die() {
  local code="$1"
  shift
  printf 'refresh-offline-payloads: %s\n' "$*" >&2
  exit "$code"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --use-cached-model-catalog)
      USE_CACHED_MODEL_CATALOG=1
      shift
      ;;
    --codex-plus-tag)
      [[ "$#" -ge 2 ]] || die 64 "--codex-plus-tag requires a release tag"
      CODEX_PLUS_TAG="$2"
      [[ "$CODEX_PLUS_TAG" =~ ^v[0-9A-Za-z._-]+$ ]] \
        || die 64 "Codex++ release tag is unsafe"
      shift 2
      ;;
    --prepare-codex-plus-compatibility-build)
      PREPARE_CODEX_PLUS_COMPATIBILITY_BUILD=1
      shift
      ;;
    *)
      die 64 "unknown argument: $1"
      ;;
  esac
done

if [[ "$PREPARE_CODEX_PLUS_COMPATIBILITY_BUILD" == 1 \
   && -z "$CODEX_PLUS_TAG" ]]; then
  die 64 "--prepare-codex-plus-compatibility-build requires --codex-plus-tag"
fi

[[ -x "$CURL_BIN" ]] || die 64 "curl command is not executable"
command -v jq >/dev/null 2>&1 || die 64 "jq is required"
[[ -f "$SOURCES_FILE" && -f "$PLUGIN_CATALOG" && -f "$MODEL_CATALOG" && -f "$SCRIPT_MARKET_OVERRIDES" ]] \
  || die 64 "resource metadata is incomplete"
jq -e '
  type == "object" and
  keys == ["overrides", "schemaVersion"] and
  .schemaVersion == 2 and
  (.overrides | type == "array") and
  all(.overrides[];
    type == "object" and (
      (.mode == "pinned" and
       keys == ["id", "mode", "pinnedSHA256", "pinnedURL", "sourceCommit", "upstreamSHA256", "upstreamURL"] and
       (.pinnedURL | type == "string" and test("^https://[^[:space:]]+$")) and
       (.pinnedSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$"))) or
      (.mode == "managed" and
       keys == ["id", "managedSHA256", "managedSource", "mode", "provenance", "upstreamSHA256", "upstreamURL"] and
       ((.managedSource | type) == "string") and
       (.managedSource | test("^[A-Za-z0-9._/-]+$")) and
       ((.managedSource | contains("..")) | not) and
       (.managedSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.provenance | type == "string" and test("^[A-Za-z0-9._:-]+$")))
    ) and
    (.id | type == "string" and test("^[A-Za-z0-9_-]+$")) and
    (.upstreamURL | type == "string" and test("^https://[^[:space:]]+$")) and
    (.upstreamSHA256 | type == "string" and test("^[0-9a-f]{64}$"))
  ) and
  (([.overrides[].id] | length) == ([.overrides[].id] | unique | length))
' "$SCRIPT_MARKET_OVERRIDES" >/dev/null || die 64 "script market overrides are invalid"

if [[ -z "$deepseek_catalog_key" && "$USE_CACHED_MODEL_CATALOG" != 1 ]]; then
  die 64 "DEEPSEEK_CATALOG_KEY is absent; pass --use-cached-model-catalog explicitly"
fi
if [[ -z "$kimi_open_catalog_key" && "$USE_CACHED_MODEL_CATALOG" != 1 ]]; then
  die 64 "KIMI_OPEN_CATALOG_KEY is absent; pass --use-cached-model-catalog explicitly"
fi

payload_base=''
payload_relative=''
if [[ "$TEST_MODE" == 1 ]]; then
  test_payload_base="${TMPDIR:-/tmp}"
  test_payload_base="${test_payload_base%/}"
  case "$OUTPUT_ROOT" in
    "$ROOT/vendor/offline-payloads")
      payload_base="$ROOT"
      payload_relative='vendor/offline-payloads'
      ;;
    "$test_payload_base"/*)
      payload_base="$test_payload_base"
      payload_relative="${OUTPUT_ROOT#"$test_payload_base"/}"
      ;;
    *) die 64 "unsafe test output root" ;;
  esac
elif [[ "$OUTPUT_ROOT" == "$ROOT/vendor/offline-payloads" ]]; then
  payload_base="$ROOT"
  payload_relative='vendor/offline-payloads'
else
  die 64 "production output root must be the repository vendor/offline-payloads directory"
fi
PAYLOAD_ROOT_BASE="$(cd -P "$payload_base" && pwd)" \
  || die 65 "payload base directory is inaccessible"
if [[ "$TEST_MODE" != 1 && "$PAYLOAD_FIND_BIN" != /usr/bin/find ]]; then
  die 64 "PAYLOAD_FIND_BIN is test-only"
fi
[[ -x "$PAYLOAD_FIND_BIN" ]] || die 64 "payload find command is not executable"

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-payload-refresh.XXXXXX")"
/bin/chmod 700 "$TEMP_ROOT"
MOUNT_POINTS_FILE="$TEMP_ROOT/mount-points"
: > "$MOUNT_POINTS_FILE"

build_support_tool() {
  if [[ -n "$SUPPORT_TOOL_PATH" ]]; then
    [[ -x "$SUPPORT_TOOL_PATH" ]] || die 64 "SUPPORT_TOOL is not executable"
    return
  fi
  SUPPORT_TOOL_PATH="$TEMP_ROOT/installer-support"
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
    -o "$SUPPORT_TOOL_PATH"
}
build_support_tool

if [[ "$USE_CACHED_MODEL_CATALOG" == 1 ]]; then
  if [[ -z "$deepseek_catalog_key" || -z "$kimi_open_catalog_key" ]]; then
    "$SUPPORT_TOOL_PATH" model-catalog-validate \
      --catalog "$MODEL_CATALOG" \
      --max-age-days 30 \
      >/dev/null || die 65 "cached model catalog is stale or invalid"
  fi
fi

chatgpt_arm_url="$(jq -er '.chatgptCodexMacArm64' "$SOURCES_FILE")"
chatgpt_x64_url="$(jq -er '.chatgptCodexMacX64' "$SOURCES_FILE")"
codex_plus_latest_url="$(jq -er '.codexPlusPlusLatest' "$SOURCES_FILE")"
codex_plus_source_template="$(jq -er '.codexPlusPlusSource' "$SOURCES_FILE")"
script_market_url="$(jq -er '.scriptMarket' "$SOURCES_FILE")"
for locked_url in "$chatgpt_arm_url" "$chatgpt_x64_url" "$codex_plus_latest_url" "$codex_plus_source_template" "$script_market_url"; do
  [[ "$locked_url" == https://* ]] || die 65 "upstream source must use HTTPS"
done
[[ "$codex_plus_source_template" == *'{tag}'* ]] || die 65 "Codex++ source template is invalid"

validate_payload_directory_path() {
  local relative="$1"
  local path="$PAYLOAD_ROOT_BASE"
  local component
  local -a components=()
  [[ -n "$relative" && "$relative" != /* ]] \
    || die 65 "payload path contains an unsafe component: $relative"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] \
      || die 65 "payload path contains an unsafe component: $relative"
    path="$path/$component"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -d "$path" && ! -L "$path" ]] \
        || die 65 "payload path contains a non-directory or symbolic link: $path"
    fi
  done
}

validate_payload_directory_path "$payload_relative"
validate_payload_directory_path "$payload_relative/apps"
validate_payload_directory_path "$payload_relative/sources"
validate_payload_directory_path "$payload_relative/metadata"

validate_existing_regular_leaf() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] \
      || die 65 "payload publication leaf is not a regular file: $target"
  fi
}

enumerate_entries() {
  local directory="$1"
  local destination="$2"
  shift 2
  if ! "$PAYLOAD_FIND_BIN" "$directory" -mindepth 1 "$@" -print0 > "$destination"; then
    die 65 "unable to enumerate payload directory: $directory"
  fi
}

validate_refresh_boundary() {
  local entry name directory entries
  local root_entries="$TEMP_ROOT/preflight-root-entries"
  local metadata_entries="$TEMP_ROOT/preflight-metadata-entries"

  for entry in \
    "$OUTPUT_ROOT/model-catalog.json" \
    "$OUTPUT_ROOT/plugin-catalog.json" \
    "$OUTPUT_ROOT/payload-manifest.json" \
    "$MODEL_CATALOG" \
    "$PLUGIN_CATALOG"; do
    validate_existing_regular_leaf "$entry"
  done
  [[ -f "$MODEL_CATALOG" && ! -L "$MODEL_CATALOG" ]] \
    || die 65 "resource model catalog is not a regular file"
  [[ -f "$PLUGIN_CATALOG" && ! -L "$PLUGIN_CATALOG" ]] \
    || die 65 "resource plugin catalog is not a regular file"

  if [[ -d "$OUTPUT_ROOT" ]]; then
    enumerate_entries "$OUTPUT_ROOT" "$root_entries" -maxdepth 1
    while IFS= read -r -d '' entry; do
      name="${entry##*/}"
      case "$name" in
        apps|metadata|plugins|script-market|sources)
          [[ -d "$entry" && ! -L "$entry" ]] \
            || die 65 "payload root entry is not a regular directory: $entry"
          ;;
        model-catalog.json|payload-manifest.json|plugin-catalog.json)
          [[ -f "$entry" && ! -L "$entry" ]] \
            || die 65 "payload publication leaf is not a regular file: $entry"
          ;;
        *)
          [[ -f "$entry" && ! -L "$entry" ]] \
            || die 65 "unexpected payload root entry is unsafe: $entry"
          ;;
      esac
    done < "$root_entries"
  fi

  if [[ -d "$OUTPUT_ROOT/metadata" ]]; then
    enumerate_entries "$OUTPUT_ROOT/metadata" "$metadata_entries" -maxdepth 1
    while IFS= read -r -d '' entry; do
      [[ -f "$entry" && ! -L "$entry" ]] \
        || die 65 "unexpected payload metadata entry is unsafe: $entry"
    done < "$metadata_entries"
  fi

  for directory in "$OUTPUT_ROOT/apps" "$OUTPUT_ROOT/sources"; do
    [[ -d "$directory" ]] || continue
    entries="$TEMP_ROOT/preflight-${directory##*/}-entries"
    enumerate_entries "$directory" "$entries"
    while IFS= read -r -d '' entry; do
      [[ -f "$entry" && ! -L "$entry" ]] \
        || die 65 "unexpected payload entry is not a regular file: $entry"
    done < "$entries"
  done
}
validate_refresh_boundary

/bin/mkdir -p "$OUTPUT_ROOT/apps" "$OUTPUT_ROOT/sources" "$OUTPUT_ROOT/metadata"
validate_payload_directory_path "$payload_relative"
validate_payload_directory_path "$payload_relative/apps"
validate_payload_directory_path "$payload_relative/sources"
validate_payload_directory_path "$payload_relative/metadata"

create_sibling_stage() {
  local destination="$1"
  local directory base
  directory="$(/usr/bin/dirname "$destination")"
  base="$(/usr/bin/basename "$destination")"
  STAGED_FILE_RESULT="$(/usr/bin/mktemp "$directory/.$base.refresh.XXXXXX")" \
    || die 65 "unable to create staged payload file: $destination"
  [[ -f "$STAGED_FILE_RESULT" && ! -L "$STAGED_FILE_RESULT" ]] \
    || die 65 "staged payload file is not regular: $destination"
  /bin/chmod 600 "$STAGED_FILE_RESULT"
  STAGED_FILES+=("$STAGED_FILE_RESULT")
}

publish_staged_file() {
  local staged="$1"
  local destination="$2"
  local mode="${3:-600}"
  [[ -f "$staged" && ! -L "$staged" ]] \
    || die 65 "staged payload file is not regular: $destination"
  validate_existing_regular_leaf "$destination"
  /bin/chmod "$mode" "$staged"
  /bin/mv -f "$staged" "$destination" \
    || die 65 "unable to publish payload file: $destination"
  [[ -f "$destination" && ! -L "$destination" ]] \
    || die 65 "published payload file is not regular: $destination"
}

is_staged_file() {
  local candidate="$1"
  local staged
  for staged in "${STAGED_FILES[@]}"; do
    [[ -n "$staged" ]] || continue
    [[ "$candidate" == "$staged" ]] && return 0
  done
  return 1
}


download() {
  local url="$1"
  local target="$2"
  local mode="${3:-cached}"
  [[ "$url" == https://* ]] || die 65 "refusing non-HTTPS download"
  if [[ "$mode" == cached && -s "$target" ]]; then
    return 0
  fi
  local partial="$target.download"
  /bin/mkdir -p "$(/usr/bin/dirname "$target")"
  /bin/rm -f "$partial"
  "$CURL_BIN" \
    --fail \
    --location \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time 1800 \
    --output "$partial" \
    "$url"
  [[ -s "$partial" ]] || die 65 "download returned an empty file"
  /bin/chmod 600 "$partial"
  /bin/mv -f "$partial" "$target"
}

release_json="$TEMP_ROOT/codex-plus-release.json"
codex_plus_release_url="$codex_plus_latest_url"
if [[ -n "$CODEX_PLUS_TAG" ]]; then
  codex_plus_release_url="https://api.github.com/repos/BigPizzaV3/CodexPlusPlus/releases/tags/$CODEX_PLUS_TAG"
fi
download "$codex_plus_release_url" "$release_json"
tag="$(jq -er '.tag_name' "$release_json")"
[[ "$tag" =~ ^v[0-9A-Za-z._-]+$ ]] || die 65 "Codex++ release tag is unsafe"
if [[ -n "$CODEX_PLUS_TAG" && "$tag" != "$CODEX_PLUS_TAG" ]]; then
  die 65 "Codex++ release metadata tag does not match requested tag"
fi
version="${tag#v}"

release_asset_url() {
  local name="$1"
  local count
  count="$(jq --arg name "$name" '[.assets[] | select(.name == $name and (.browser_download_url | type == "string"))] | length' "$release_json")"
  [[ "$count" == 1 ]] || die 65 "release asset is missing or ambiguous: $name"
  local url
  url="$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")"
  [[ "$url" == https://* ]] || die 65 "release asset URL must use HTTPS: $name"
  printf '%s' "$url"
}

arm_name="CodexPlusPlus-$version-macos-arm64.dmg"
x64_name="CodexPlusPlus-$version-macos-x64.dmg"
arm_url="$(release_asset_url "$arm_name")"
x64_url="$(release_asset_url "$x64_name")"
source_url="${codex_plus_source_template//\{tag\}/$tag}"

chatgpt_arm_dmg="$OUTPUT_ROOT/apps/Codex-arm64.dmg"
chatgpt_x64_dmg="$OUTPUT_ROOT/apps/Codex-x64.dmg"
arm_dmg="$OUTPUT_ROOT/apps/$arm_name"
x64_dmg="$OUTPUT_ROOT/apps/$x64_name"
source_archive="$OUTPUT_ROOT/sources/CodexPlusPlus-$tag.tar.gz"
download "$chatgpt_arm_url" "$chatgpt_arm_dmg" fresh
download "$chatgpt_x64_url" "$chatgpt_x64_dmg" fresh
download "$arm_url" "$arm_dmg"
download "$x64_url" "$x64_dmg"
download "$source_url" "$source_archive"

inspect_dmg_native() {
  local dmg="$1"
  local component="$2"
  local attachment="$TEMP_ROOT/attach-$RANDOM.plist"
  /usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$dmg" > "$attachment"
  local index=0 mount_point=''
  while [[ "$index" -lt 32 ]]; do
    mount_point="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$attachment" 2>/dev/null || true)"
    [[ -n "$mount_point" ]] && break
    index=$((index + 1))
  done
  [[ -n "$mount_point" && -d "$mount_point" ]] || die 66 "unable to resolve DMG mount point"
  printf '%s\n' "$mount_point" >> "$MOUNT_POINTS_FILE"

  local -a app_paths=()
  local -a expected_bundles=()
  if [[ "$component" == chatgpt ]]; then
    [[ "$(/usr/bin/find "$mount_point" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 \
       && -d "$mount_point/ChatGPT.app" ]] || {
      /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
      die 66 "official Codex DMG must contain exactly ChatGPT.app"
    }
    app_paths=("$mount_point/ChatGPT.app")
    expected_bundles=("com.openai.codex")
  else
    [[ "$(/usr/bin/find "$mount_point" -maxdepth 1 -type d -name '*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 2 \
       && -d "$mount_point/Codex++.app" \
       && -d "$mount_point/Codex++ 管理工具.app" ]] || {
      /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
      die 66 "Codex++ DMG must contain exactly the launcher and manager apps"
    }
    app_paths=("$mount_point/Codex++.app" "$mount_point/Codex++ 管理工具.app")
    expected_bundles=("com.bigpizzav3.codexplusplus" "com.bigpizzav3.codexplusplus.manager")
  fi

  local app plist bundle app_version executable architectures team app_architecture_json
  local -a app_architectures=()
  local common_version=''
  local common_team=''
  local architecture_lines="$TEMP_ROOT/architectures-$RANDOM"
  local application_lines="$TEMP_ROOT/applications-$RANDOM"
  : > "$architecture_lines"
  : > "$application_lines"
  for index in "${!app_paths[@]}"; do
    app="${app_paths[$index]}"
    plist="$app/Contents/Info.plist"
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
    [[ "$bundle" == "${expected_bundles[$index]}" && -n "$app_version" \
       && -f "$app/Contents/MacOS/$executable" ]] || die 66 "DMG application identity is invalid"
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
      || die 66 "DMG application signature verification failed"
    team="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
    architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable" 2>/dev/null)"
    [[ -n "$architectures" ]] || die 66 "DMG application architecture is missing"
    app_architectures=()
    read -r -a app_architectures <<< "$architectures"
    printf '%s\n' "${app_architectures[@]}" >> "$architecture_lines"
    app_architecture_json="$(printf '%s\n' "${app_architectures[@]}" | LC_ALL=C /usr/bin/sort -u | jq -R . | jq -s .)"
    jq -cn \
      --arg bundleIdentifier "$bundle" \
      --arg version "$app_version" \
      --arg teamIdentifier "$team" \
      --argjson architectures "$app_architecture_json" \
      '{bundleIdentifier:$bundleIdentifier,version:$version,architectures:$architectures,teamIdentifier:$teamIdentifier}' \
      >> "$application_lines"
    if [[ -z "$common_version" ]]; then common_version="$app_version"; fi
    [[ "$app_version" == "$common_version" ]] || die 66 "DMG application versions do not match"
    if [[ "$component" == chatgpt ]]; then
      [[ "$team" == 2DC432GLL2 ]] || die 66 "official Codex Team ID is invalid"
      common_team="$team"
    fi
  done
  /usr/bin/hdiutil detach "$mount_point" >/dev/null

  local architecture_json bundle_json applications_json
  architecture_json="$(LC_ALL=C /usr/bin/sort -u "$architecture_lines" | jq -R . | jq -s .)"
  bundle_json="$(printf '%s\n' "${expected_bundles[@]}" | jq -R . | jq -s .)"
  applications_json="$(jq -s . "$application_lines")"
  jq -cn \
    --arg version "$common_version" \
    --arg teamIdentifier "$common_team" \
    --argjson architectures "$architecture_json" \
    --argjson bundleIdentifiers "$bundle_json" \
    --argjson applications "$applications_json" \
    '{version:$version,architectures:$architectures,bundleIdentifiers:$bundleIdentifiers,teamIdentifier:$teamIdentifier,applications:$applications}'
}

inspect_dmg() {
  local dmg="$1"
  local component="$2"
  if [[ -n "$APP_INSPECT_BIN" ]]; then
    [[ "$TEST_MODE" == 1 && -x "$APP_INSPECT_BIN" ]] || die 64 "APP_INSPECT_BIN is test-only"
    "$APP_INSPECT_BIN" "$dmg" "$component"
  else
    inspect_dmg_native "$dmg" "$component"
  fi
}

chat_arm_info="$TEMP_ROOT/chat-arm-info.json"
chat_x64_info="$TEMP_ROOT/chat-x64-info.json"
arm_info="$TEMP_ROOT/arm-info.json"
x64_info="$TEMP_ROOT/x64-info.json"
inspect_dmg "$chatgpt_arm_dmg" chatgpt > "$chat_arm_info"
inspect_dmg "$chatgpt_x64_dmg" chatgpt > "$chat_x64_info"
inspect_dmg "$arm_dmg" codex-plus-plus > "$arm_info"
inspect_dmg "$x64_dmg" codex-plus-plus > "$x64_info"
jq -e '
  .bundleIdentifiers == ["com.openai.codex"] and
  .teamIdentifier == "2DC432GLL2" and
  (.architectures | index("arm64") != null) and
  (.version | type == "string" and length > 0)
' "$chat_arm_info" >/dev/null || die 66 "official Codex arm64 DMG identity is invalid"
jq -e '
  .bundleIdentifiers == ["com.openai.codex"] and
  .teamIdentifier == "2DC432GLL2" and
  (.architectures | index("x86_64") != null) and
  (.version | type == "string" and length > 0)
' "$chat_x64_info" >/dev/null || die 66 "official Codex x86_64 DMG identity is invalid"
[[ "$(jq -er '.version' "$chat_arm_info")" == "$(jq -er '.version' "$chat_x64_info")" ]] \
  || die 66 "official Codex architecture versions do not match"
jq -e --arg version "$version" --arg architecture arm64 '
  .version == $version and
  ([.applications[].bundleIdentifier] | sort) == ([
    "com.bigpizzav3.codexplusplus",
    "com.bigpizzav3.codexplusplus.manager"
  ] | sort) and
  all(.applications[];
    .version == $version and
    (.architectures | index($architecture) != null))
' "$arm_info" >/dev/null || die 66 "Codex++ arm64 DMG identity is invalid"
jq -e --arg version "$version" --arg architecture x86_64 '
  .version == $version and
  ([.applications[].bundleIdentifier] | sort) == ([
    "com.bigpizzav3.codexplusplus",
    "com.bigpizzav3.codexplusplus.manager"
  ] | sort) and
  all(.applications[];
    .version == $version and
    (.architectures | index($architecture) != null))
' "$x64_info" >/dev/null || die 66 "Codex++ x64 DMG identity is invalid"
chatgpt_version="$(jq -er '.version' "$chat_arm_info")"

is_current_payload_target() {
  case "$1" in
    "$chatgpt_arm_dmg"|"$chatgpt_x64_dmg"|"$arm_dmg"|"$x64_dmg"|"$source_archive") return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_payload_snapshot() {
  local directory entry entries name
  local apps_entries="$TEMP_ROOT/payload-app-entries-$RANDOM"
  local sources_entries="$TEMP_ROOT/payload-source-entries-$RANDOM"
  local root_entries="$TEMP_ROOT/payload-root-entries-$RANDOM"
  local metadata_entries="$TEMP_ROOT/payload-metadata-entries-$RANDOM"

  for entry in "$chatgpt_arm_dmg" "$chatgpt_x64_dmg" "$arm_dmg" "$x64_dmg" "$source_archive"; do
    [[ -f "$entry" && ! -L "$entry" && -s "$entry" ]] \
      || die 65 "current payload target is not a regular file: $entry"
  done

  for directory in "$OUTPUT_ROOT/apps" "$OUTPUT_ROOT/sources"; do
    [[ -d "$directory" && ! -L "$directory" ]] \
      || die 65 "payload directory is not a regular directory: $directory"
    case "$directory" in
      "$OUTPUT_ROOT/apps") entries="$apps_entries" ;;
      "$OUTPUT_ROOT/sources") entries="$sources_entries" ;;
    esac
    enumerate_entries "$directory" "$entries"
  done

  enumerate_entries "$OUTPUT_ROOT" "$root_entries" -maxdepth 1
  enumerate_entries "$OUTPUT_ROOT/metadata" "$metadata_entries" -maxdepth 1

  for entries in "$apps_entries" "$sources_entries"; do
    while IFS= read -r -d '' entry; do
      if is_current_payload_target "$entry"; then
        [[ -f "$entry" && ! -L "$entry" && -s "$entry" ]] \
          || die 65 "current payload target is not a regular file: $entry"
      elif [[ -L "$entry" || ! -f "$entry" ]]; then
        die 65 "unexpected payload entry is not a regular file: $entry"
      fi
    done < "$entries"
  done

  while IFS= read -r -d '' entry; do
    if is_staged_file "$entry"; then
      [[ -f "$entry" && ! -L "$entry" ]] \
        || die 65 "staged payload file is not regular: $entry"
      continue
    fi
    name="${entry##*/}"
    case "$name" in
      apps|metadata|plugins|script-market|sources)
        [[ -d "$entry" && ! -L "$entry" ]] \
          || die 65 "payload root entry is not a regular directory: $entry"
        ;;
      model-catalog.json|payload-manifest.json|plugin-catalog.json)
        validate_existing_regular_leaf "$entry"
        ;;
      *)
        [[ -f "$entry" && ! -L "$entry" ]] \
          || die 65 "unexpected payload root entry is unsafe: $entry"
        ;;
    esac
  done < "$root_entries"
  while IFS= read -r -d '' entry; do
    [[ -f "$entry" && ! -L "$entry" ]] \
      || die 65 "unexpected payload metadata entry is unsafe: $entry"
  done < "$metadata_entries"

  for entries in "$apps_entries" "$sources_entries"; do
    while IFS= read -r -d '' entry; do
      is_current_payload_target "$entry" || /bin/rm -f -- "$entry"
    done < "$entries"
  done
  while IFS= read -r -d '' entry; do
    is_staged_file "$entry" && continue
    name="${entry##*/}"
    case "$name" in
      apps|metadata|plugins|script-market|sources|model-catalog.json|payload-manifest.json|plugin-catalog.json) ;;
      *) /bin/rm -f "$entry" ;;
    esac
  done < "$root_entries"
  while IFS= read -r -d '' entry; do
    /bin/rm -f "$entry"
  done < "$metadata_entries"
  /bin/rm -f "$apps_entries" "$sources_entries" "$root_entries" "$metadata_entries"
}

snapshot_plugins() {
  local plugin_root="$OUTPUT_ROOT/plugins"
  /bin/rm -R "$plugin_root" 2>/dev/null || true
  /bin/mkdir -p "$plugin_root/marketplaces" "$plugin_root/cache"

  local marketplace source
  for marketplace in openai-bundled openai-primary-runtime openai-curated; do
    case "$marketplace" in
      openai-bundled)
        source="$BUILDER_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
        ;;
      openai-primary-runtime)
        source="$BUILDER_HOME/.cache/codex-runtimes/codex-primary-runtime/plugins/openai-primary-runtime"
        ;;
      openai-curated)
        source="$BUILDER_HOME/.codex/.tmp/plugins"
        ;;
    esac
    [[ -f "$source/.agents/plugins/marketplace.json" ]] \
      || die 67 "missing marketplace $marketplace"
    if /usr/bin/find "$source" -type l -print -quit | /usr/bin/grep -q .; then
      die 67 "marketplace contains a symbolic link: $marketplace"
    fi
    /usr/bin/ditto "$source" "$plugin_root/marketplaces/$marketplace"
  done

  while IFS=$'\t' read -r marketplace plugin; do
    local market_source expected_json expected_name expected_version cache_root candidate selected=''
    market_source="$plugin_root/marketplaces/$marketplace"
    expected_json="$market_source/plugins/$plugin/.codex-plugin/plugin.json"
    [[ -f "$expected_json" ]] || die 67 "missing plugin $plugin@$marketplace"
    expected_name="$(jq -er '.name' "$expected_json")"
    expected_version="$(jq -er '.version' "$expected_json")"
    [[ "$expected_name" == "$plugin" && -n "$expected_version" && "$expected_version" != */* ]] \
      || die 67 "invalid plugin identity $plugin@$marketplace"
    cache_root="$BUILDER_HOME/.codex/plugins/cache/$marketplace/$plugin"
    [[ -d "$cache_root" ]] || die 67 "missing plugin cache $plugin@$marketplace"
    while IFS= read -r -d '' candidate; do
      local candidate_json candidate_name candidate_version
      candidate_json="$candidate/.codex-plugin/plugin.json"
      candidate_name="$(jq -er '.name' "$candidate_json" 2>/dev/null || true)"
      candidate_version="$(jq -er '.version' "$candidate_json" 2>/dev/null || true)"
      if [[ "$candidate_name" == "$plugin" && "$candidate_version" == "$expected_version" ]]; then
        [[ -z "$selected" ]] || die 67 "ambiguous plugin cache $plugin@$marketplace"
        selected="$candidate"
      fi
    done < <(/usr/bin/find "$cache_root" -mindepth 1 -maxdepth 1 -type d -print0)
    [[ -n "$selected" ]] || die 67 "missing plugin cache $plugin@$marketplace"
    if /usr/bin/find "$selected" -type l -print -quit | /usr/bin/grep -q .; then
      die 67 "plugin cache contains a symbolic link: $plugin@$marketplace"
    fi
    /usr/bin/ditto "$selected" "$plugin_root/cache/$marketplace/$plugin/$expected_version"
  done < <(jq -r '.plugins[] | [.marketplace,.id] | @tsv' "$plugin_catalog_stage")

  (
    cd "$plugin_root"
    /usr/bin/find marketplaces cache -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r relative; do
      [[ "$relative" != *$'\n'* ]] || die 67 "plugin package contains an unsafe filename"
      digest="$(/usr/bin/shasum -a 256 "$relative" | /usr/bin/awk '{print tolower($1)}')"
      jq -cn --arg path "$relative" --arg sha256 "$digest" '{path:$path,sha256:$sha256}'
    done | jq -s '{schemaVersion:1,files:.}' > file-manifest.json
  )
  "$SUPPORT_TOOL_PATH" plugin-package-validate \
    --root "$plugin_root" \
    --catalog "$plugin_catalog_stage" \
    >/dev/null || die 67 "plugin snapshot validation failed"
}
create_sibling_stage "$OUTPUT_ROOT/plugin-catalog.json"
plugin_catalog_stage="$STAGED_FILE_RESULT"
/bin/cp "$PLUGIN_CATALOG" "$plugin_catalog_stage"
snapshot_plugins

snapshot_script_market() {
  local destination="$OUTPUT_ROOT/script-market"
  /bin/rm -R "$destination" 2>/dev/null || true
  /bin/mkdir -p "$destination/scripts"
  download "$script_market_url" "$destination/index.json"
  jq -e '
    (.version | type == "number") and
    (.scripts | type == "array" and length > 0) and
    all(.scripts[];
      (.id | type == "string" and test("^[A-Za-z0-9_-]+$")) and
      (.name | type == "string" and length > 0) and
      (.version | type == "string" and length > 0) and
      (.script_url | type == "string" and startswith("https://")) and
      (.sha256 | type == "string" and test("^[A-Fa-f0-9]{64}$"))) and
    (([.scripts[].id] | length) == ([.scripts[].id] | unique | length))
  ' "$destination/index.json" >/dev/null || die 68 "script market index is invalid"

  apply_script_override() {
    local id="$1"
    local url="$2"
    local target="$3"
    local upstream_sha="$4"
    local override_count
    override_count="$(jq -r --arg id "$id" '[.overrides[] | select(.id == $id and .mode == "pinned")] | length' "$SCRIPT_MARKET_OVERRIDES")"
    [[ "$override_count" == 1 ]] || die 68 "script payload hash mismatch: $id"

    local override_url override_sha pinned_url pinned_sha source_commit
    override_url="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "pinned") | .upstreamURL' "$SCRIPT_MARKET_OVERRIDES")"
    override_sha="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "pinned") | .upstreamSHA256' "$SCRIPT_MARKET_OVERRIDES")"
    pinned_url="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "pinned") | .pinnedURL' "$SCRIPT_MARKET_OVERRIDES")"
    pinned_sha="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "pinned") | .pinnedSHA256' "$SCRIPT_MARKET_OVERRIDES")"
    source_commit="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "pinned") | .sourceCommit' "$SCRIPT_MARKET_OVERRIDES")"
    [[ "$override_url" == "$url" && "$override_sha" == "$upstream_sha" ]] \
      || die 68 "script payload hash mismatch: $id"

    local pinned="$TEMP_ROOT/script-pinned-$id"
    download "$pinned_url" "$pinned"
    [[ "$(/usr/bin/shasum -a 256 "$pinned" | /usr/bin/awk '{print tolower($1)}')" == "$pinned_sha" ]] \
      || die 68 "pinned script payload hash mismatch: $id"
    /bin/mv -f "$pinned" "$target"

    jq \
      --arg id "$id" \
      --arg upstream "$upstream_sha" \
      --arg sha256 "$pinned_sha" \
      --arg commit "$source_commit" \
      --arg url "$pinned_url" \
      '(.scripts[] | select(.id == $id)) |= (
        .upstream_sha256 = $upstream |
        .sha256 = $sha256 |
        .source_commit = $commit |
        .script_url = $url
      )' "$destination/index.json" > "$destination/index.pinned.json"
    /bin/mv -f "$destination/index.pinned.json" "$destination/index.json"
  }

  apply_managed_script_source() {
    local id="$1"
    local url="$2"
    local target="$3"
    local upstream_sha="$4"
    local managed_count
    managed_count="$(jq -r --arg id "$id" '[.overrides[] | select(.id == $id and .mode == "managed")] | length' "$SCRIPT_MARKET_OVERRIDES")"
    [[ "$managed_count" == 0 ]] && return 1
    [[ "$managed_count" == 1 ]] || die 68 "managed script source is ambiguous: $id"

    local override_url override_sha managed_source managed_sha provenance source_path actual
    override_url="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "managed") | .upstreamURL' "$SCRIPT_MARKET_OVERRIDES")"
    override_sha="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "managed") | .upstreamSHA256' "$SCRIPT_MARKET_OVERRIDES")"
    managed_source="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "managed") | .managedSource' "$SCRIPT_MARKET_OVERRIDES")"
    managed_sha="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "managed") | .managedSHA256' "$SCRIPT_MARKET_OVERRIDES")"
    provenance="$(jq -er --arg id "$id" '.overrides[] | select(.id == $id and .mode == "managed") | .provenance' "$SCRIPT_MARKET_OVERRIDES")"
    [[ "$override_url" == "$url" && "$override_sha" == "$upstream_sha" ]] \
      || die 68 "managed script upstream lock mismatch: $id"
    source_path="$RESOURCE_DIR/$managed_source"
    [[ -f "$source_path" && ! -L "$source_path" ]] || die 68 "managed script source is missing or unsafe: $id"
    actual="$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{print tolower($1)}')"
    [[ "$actual" == "$managed_sha" ]] || die 68 "managed script source hash mismatch: $id"
    /bin/cp "$source_path" "$target"

    jq \
      --arg id "$id" \
      --arg upstream "$upstream_sha" \
      --arg sha256 "$managed_sha" \
      --arg source "$managed_source" \
      --arg provenance "$provenance" \
      '(.scripts[] | select(.id == $id)) |= (
        .upstream_sha256 = $upstream |
        .sha256 = $sha256 |
        .script_url = ("managed://" + $source) |
        .source_commit = ("managed:" + $provenance) |
        .managed_source = $source |
        .managed_sha256 = $sha256 |
        .provenance = $provenance
      )' "$destination/index.json" > "$destination/index.managed.json"
    /bin/mv -f "$destination/index.managed.json" "$destination/index.json"
  }

  local id url expected expected_sha target actual
  while IFS=$'\t' read -r id url expected; do
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ && "$url" == https://* ]] \
      || die 68 "script market entry is unsafe: $id"
    target="$destination/scripts/$id.js"
    download "$url" "$target"
    [[ -s "$target" ]] || die 68 "script payload is empty: $id"
    actual="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print tolower($1)}')"
    expected_sha="$(printf '%s' "$expected" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if apply_managed_script_source "$id" "$url" "$target" "$expected_sha"; then
      actual="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print tolower($1)}')"
      [[ "$actual" == "$(jq -er --arg id "$id" '.scripts[] | select(.id == $id) | .sha256 | ascii_downcase' "$destination/index.json")" ]] \
        || die 68 "managed script payload hash mismatch: $id"
    elif [[ "$actual" != "$expected_sha" ]]; then
      apply_script_override "$id" "$url" "$target" "$expected_sha"
      actual="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print tolower($1)}')"
      [[ "$actual" == "$(jq -er --arg id "$id" '.scripts[] | select(.id == $id) | .sha256 | ascii_downcase' "$destination/index.json")" ]] \
        || die 68 "pinned script payload hash mismatch: $id"
    fi
  done < <(jq -r '.scripts[] | [.id,.script_url,.sha256] | @tsv' "$destination/index.json")
  jq '.scripts |= map(.sha256 |= ascii_downcase)' "$destination/index.json" > "$destination/index.normalized.json"
  /bin/mv -f "$destination/index.normalized.json" "$destination/index.json"
}
snapshot_script_market

create_sibling_stage "$OUTPUT_ROOT/model-catalog.json"
model_catalog_stage="$STAGED_FILE_RESULT"
/bin/cp "$MODEL_CATALOG" "$model_catalog_stage"
if [[ -n "$deepseek_catalog_key" ]]; then
  printf '%s' "$deepseek_catalog_key" | "$SUPPORT_TOOL_PATH" refresh-models \
    --provider deepseek \
    --catalog "$model_catalog_stage" \
    --key-stdin \
    >/dev/null
fi
deepseek_catalog_key=''
unset deepseek_catalog_key
if [[ -n "$kimi_open_catalog_key" ]]; then
  printf '%s' "$kimi_open_catalog_key" | "$SUPPORT_TOOL_PATH" refresh-models \
    --provider kimi-open \
    --catalog "$model_catalog_stage" \
    --key-stdin \
    >/dev/null
fi
kimi_open_catalog_key=''
unset kimi_open_catalog_key
"$SUPPORT_TOOL_PATH" model-catalog-validate \
  --catalog "$model_catalog_stage" \
  --max-age-days 30 \
  >/dev/null || die 65 "refreshed model catalog is invalid"
create_sibling_stage "$RESOURCE_DIR/model-catalog.json"
resource_model_catalog_stage="$STAGED_FILE_RESULT"
/bin/cp "$model_catalog_stage" "$resource_model_catalog_stage"

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print tolower($1)}'
}

chat_arm_sha="$(sha256_file "$chatgpt_arm_dmg")"
chat_x64_sha="$(sha256_file "$chatgpt_x64_dmg")"
arm_sha="$(sha256_file "$arm_dmg")"
x64_sha="$(sha256_file "$x64_dmg")"
source_sha="$(sha256_file "$source_archive")"
plugin_sha="$(sha256_file "$OUTPUT_ROOT/plugins/file-manifest.json")"
script_sha="$(sha256_file "$OUTPUT_ROOT/script-market/index.json")"
snapshot_version="${GENERATED_AT%%T*}"

create_sibling_stage "$OUTPUT_ROOT/payload-manifest.json"
manifest_stage="$STAGED_FILE_RESULT"
jq -n \
  --arg generatedAt "$GENERATED_AT" \
  --arg chatVersion "$chatgpt_version" \
  --arg chatArmSHA "$chat_arm_sha" \
  --arg chatArmURL "$chatgpt_arm_url" \
  --arg chatX64SHA "$chat_x64_sha" \
  --arg chatX64URL "$chatgpt_x64_url" \
  --arg version "$version" \
  --arg armName "$arm_name" \
  --arg armSHA "$arm_sha" \
  --arg armURL "$arm_url" \
  --arg x64Name "$x64_name" \
  --arg x64SHA "$x64_sha" \
  --arg x64URL "$x64_url" \
  --arg sourceName "CodexPlusPlus-$tag.tar.gz" \
  --arg sourceSHA "$source_sha" \
  --arg sourceURL "$source_url" \
  --arg snapshotVersion "$snapshot_version" \
  --arg pluginSHA "$plugin_sha" \
  --arg scriptSHA "$script_sha" \
  --arg scriptURL "$script_market_url" \
  --arg modelSHA "$(sha256_file "$model_catalog_stage")" \
  '{
    schemaVersion:1,
    generatedAt:$generatedAt,
    files:[
      {id:"chatgpt-codex-arm64",version:$chatVersion,architecture:"arm64",relativePath:"apps/Codex-arm64.dmg",sha256:$chatArmSHA,sourceURL:$chatArmURL,format:"dmg",bundleIdentifier:"com.openai.codex",teamIdentifier:"2DC432GLL2"},
      {id:"chatgpt-codex-x86_64",version:$chatVersion,architecture:"x86_64",relativePath:"apps/Codex-x64.dmg",sha256:$chatX64SHA,sourceURL:$chatX64URL,format:"dmg",bundleIdentifier:"com.openai.codex",teamIdentifier:"2DC432GLL2"},
      {id:"codex-plus-plus-arm64",version:$version,architecture:"arm64",relativePath:("apps/"+$armName),sha256:$armSHA,sourceURL:$armURL,format:"dmg",licenseID:"AGPL-3.0-only"},
      {id:"codex-plus-plus-x86_64",version:$version,architecture:"x86_64",relativePath:("apps/"+$x64Name),sha256:$x64SHA,sourceURL:$x64URL,format:"dmg",licenseID:"AGPL-3.0-only"},
      {id:"plugin-marketplaces",version:$snapshotVersion,architecture:"any",relativePath:"plugins",sha256:$pluginSHA,sourceURL:$chatArmURL,format:"directory"},
      {id:"script-market",version:$snapshotVersion,architecture:"any",relativePath:"script-market",sha256:$scriptSHA,sourceURL:$scriptURL,format:"directory"},
      {id:"codex-plus-plus-source",version:$version,architecture:"source",relativePath:("sources/"+$sourceName),sha256:$sourceSHA,sourceURL:$sourceURL,format:"archive",licenseID:"AGPL-3.0-only"},
      {id:"model-catalog",version:$snapshotVersion,architecture:"any",relativePath:"model-catalog.json",sha256:$modelSHA,sourceURL:$chatArmURL,format:"file"}
    ]
  }' > "$manifest_stage"

if [[ "$PREPARE_CODEX_PLUS_COMPATIBILITY_BUILD" == 1 ]]; then
  TEST_MODE=1 "$SUPPORT_TOOL_PATH" manifest-validate "$manifest_stage" >/dev/null \
    || die 65 "generated compatibility-build input manifest is invalid"
else
  "$SUPPORT_TOOL_PATH" manifest-validate "$manifest_stage" >/dev/null \
    || die 65 "generated payload manifest is invalid"
fi

cleanup_payload_snapshot
publish_staged_file "$model_catalog_stage" "$OUTPUT_ROOT/model-catalog.json"
publish_staged_file "$plugin_catalog_stage" "$OUTPUT_ROOT/plugin-catalog.json"
publish_staged_file "$resource_model_catalog_stage" "$RESOURCE_DIR/model-catalog.json" 644
publish_staged_file "$manifest_stage" "$OUTPUT_ROOT/payload-manifest.json"

validate_complete_payload_root() {
  local entry name count=0
  local root_entries="$TEMP_ROOT/final-root-entries"
  local metadata_entries="$TEMP_ROOT/final-metadata-entries"
  enumerate_entries "$OUTPUT_ROOT" "$root_entries" -maxdepth 1
  while IFS= read -r -d '' entry; do
    count=$((count + 1))
    name="${entry##*/}"
    case "$name" in
      apps|metadata|plugins|script-market|sources)
        [[ -d "$entry" && ! -L "$entry" ]] \
          || die 65 "payload root entry is not a regular directory: $entry"
        ;;
      model-catalog.json|payload-manifest.json|plugin-catalog.json)
        [[ -f "$entry" && ! -L "$entry" ]] \
          || die 65 "payload publication leaf is not a regular file: $entry"
        ;;
      *) die 65 "payload root contains an unexpected entry: $entry" ;;
    esac
  done < "$root_entries"
  [[ "$count" -eq 8 ]] || die 65 "payload root is incomplete"
  enumerate_entries "$OUTPUT_ROOT/metadata" "$metadata_entries" -maxdepth 1
  [[ ! -s "$metadata_entries" ]] || die 65 "payload metadata directory is not empty"
}
validate_complete_payload_root

printf 'refresh-offline-payloads: completed Codex %s and Codex++ %s\n' \
  "$chatgpt_version" "$version"
