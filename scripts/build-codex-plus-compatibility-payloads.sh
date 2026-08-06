#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPSTREAM_VERSION='1.2.44'
PATCH_REVISION='codexkit.1'
COMPATIBILITY_REVISION='cross-provider-content-v1'
ARM_TARGET='aarch64-apple-darwin'
X64_TARGET='x86_64-apple-darwin'
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/fancr-code/Uni-codex/releases/download/v1.0.1}"
TEST_MODE="${TEST_MODE:-0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT/vendor/offline-payloads}"
SOURCE_ARCHIVE="${SOURCE_ARCHIVE:-$OUTPUT_ROOT/sources/CodexPlusPlus-v$UPSTREAM_VERSION.tar.gz}"
PATCH_FILE="${PATCH_FILE:-$ROOT/patches/CodexPlusPlus/v$UPSTREAM_VERSION-cross-provider-history.patch}"
FIXTURE_FILE="${FIXTURE_FILE:-$ROOT/tests/fixtures/codex-plus/cross_provider_content.rs}"
PATCH_BIN="${PATCH_BIN:-/usr/bin/patch}"
NPM_BIN="${NPM_BIN:-$(command -v npm || true)}"
CARGO_BIN="${CARGO_BIN:-$(command -v cargo || true)}"
APP_INSPECT_BIN="${APP_INSPECT_BIN:-}"
TEMP_ROOT=''
MOUNT_POINTS_FILE=''

die() {
  local code="$1"
  shift
  printf 'build-codex-plus-compatibility-payloads: %s\n' "$*" >&2
  exit "$code"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$MOUNT_POINTS_FILE" && -f "$MOUNT_POINTS_FILE" ]]; then
    while IFS= read -r mount_point; do
      [[ -n "$mount_point" ]] || continue
      /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    done < "$MOUNT_POINTS_FILE"
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    /bin/rm -R "$TEMP_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

[[ "$TEST_MODE" == 0 || "$TEST_MODE" == 1 ]] || die 64 "TEST_MODE must be 0 or 1"
if [[ "$TEST_MODE" != 1 && "$OUTPUT_ROOT" != "$ROOT/vendor/offline-payloads" ]]; then
  die 64 "production output root must be the repository vendor/offline-payloads directory"
fi
for required_file in "$SOURCE_ARCHIVE" "$PATCH_FILE" "$FIXTURE_FILE" "$OUTPUT_ROOT/payload-manifest.json"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] || die 64 "required file is missing or unsafe: $required_file"
done
for required_command in "$PATCH_BIN" "$NPM_BIN" "$CARGO_BIN"; do
  [[ -n "$required_command" && -x "$required_command" ]] || die 64 "required command is not executable: $required_command"
done
command -v jq >/dev/null 2>&1 || die 64 "jq is required"
PREVIOUS_CODEX_PLUS_PATHS="$(
  jq -r '
    .files[]
    | select(.id | startswith("codex-plus-plus-"))
    | .relativePath
  ' "$OUTPUT_ROOT/payload-manifest.json"
)"

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-plus-compatibility-build.XXXXXX")"
/bin/chmod 700 "$TEMP_ROOT"
MOUNT_POINTS_FILE="$TEMP_ROOT/mount-points"
: > "$MOUNT_POINTS_FILE"
EXTRACT_ROOT="$TEMP_ROOT/extracted"
STAGE_ROOT="$TEMP_ROOT/publication"
arm_name="CodexPlusPlus-$UPSTREAM_VERSION-$PATCH_REVISION-macos-arm64.dmg"
x64_name="CodexPlusPlus-$UPSTREAM_VERSION-$PATCH_REVISION-macos-x64.dmg"
source_name="CodexPlusPlus-v$UPSTREAM_VERSION-$PATCH_REVISION.tar.gz"
/bin/mkdir -p "$EXTRACT_ROOT" "$STAGE_ROOT/apps" "$STAGE_ROOT/sources"

/usr/bin/tar -xzf "$SOURCE_ARCHIVE" -C "$EXTRACT_ROOT"
SOURCE_ROOT=''
source_count=0
while IFS= read -r candidate; do
  source_count=$((source_count + 1))
  SOURCE_ROOT="$candidate"
done < <(/usr/bin/find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d -print)
[[ "$source_count" == 1 \
   && "$(basename "$SOURCE_ROOT")" == "CodexPlusPlus-$UPSTREAM_VERSION" \
   && -f "$SOURCE_ROOT/Cargo.toml" ]] \
  || die 65 "source archive must contain CodexPlusPlus-$UPSTREAM_VERSION as its only top-level directory"

(
  cd "$SOURCE_ROOT"
  "$PATCH_BIN" --batch --fuzz=0 -p1 < "$PATCH_FILE"
)
/bin/cp "$FIXTURE_FILE" \
  "$SOURCE_ROOT/crates/codex-plus-core/tests/codexkit_cross_provider_content.rs"

patch_sha="$(/usr/bin/shasum -a 256 "$PATCH_FILE" | /usr/bin/awk '{print $1}')"
cat > "$SOURCE_ROOT/CODEXKIT-PATCH.md" <<EOF
# CodexKit compatibility build

- Upstream: https://github.com/BigPizzaV3/CodexPlusPlus
- Upstream tag: v$UPSTREAM_VERSION
- Downstream revision: $PATCH_REVISION
- Compatibility revision: $COMPATIBILITY_REVISION
- Patch: patches/CodexPlusPlus/v$UPSTREAM_VERSION-cross-provider-history.patch
- Patch SHA-256: $patch_sha

Downstream fixes:

- Normalize cross-provider historical message content before chat-completions forwarding.
- Remove \`style\` from the macOS Dream Skin root MutationObserver filters while retaining
  \`class\`, \`data-theme\`, \`data-appearance\`, and \`data-color-mode\`.
- Align upstream Dream Skin import tests with macOS JPEG conversion behavior.
- Avoid lossy re-encoding when a managed macOS Dream Skin image is already JPEG.
- Refresh v1.2.44 upstream theme asset SHA-256 fixtures without altering the assets.

Build sequence:

1. Apply the patch with \`patch --batch --fuzz=0 -p1\`.
2. Run the targeted protocol regression test.
3. Test and build the manager frontend.
4. Build Rust targets $ARM_TARGET and $X64_TARGET.
5. Package and inspect both architecture-specific DMGs.
EOF

export CODEX_PLUS_BUILD_SOURCE_ROOT="$SOURCE_ROOT"
BUILD_TARGET_ROOT="${CARGO_TARGET_DIR:-$SOURCE_ROOT/target}"
"$NPM_BIN" --prefix "$SOURCE_ROOT/apps/codex-plus-manager" ci
"$NPM_BIN" --prefix "$SOURCE_ROOT/apps/codex-plus-manager" test
"$NPM_BIN" --prefix "$SOURCE_ROOT/apps/codex-plus-manager" run check
"$NPM_BIN" --prefix "$SOURCE_ROOT/apps/codex-plus-manager" run vite:build
(
  cd "$SOURCE_ROOT"
  "$CARGO_BIN" fmt --all -- --check
  "$CARGO_BIN" test --workspace
)
"$CARGO_BIN" test \
  --manifest-path "$SOURCE_ROOT/Cargo.toml" \
  -p codex-plus-core \
  --test codexkit_cross_provider_content
"$CARGO_BIN" build \
  --manifest-path "$SOURCE_ROOT/Cargo.toml" \
  --release \
  --target "$ARM_TARGET"
"$CARGO_BIN" build \
  --manifest-path "$SOURCE_ROOT/Cargo.toml" \
  --release \
  --target "$X64_TARGET"

COPYFILE_DISABLE=1 /usr/bin/tar -czf "$STAGE_ROOT/sources/$source_name" \
  -C "$EXTRACT_ROOT" "CodexPlusPlus-$UPSTREAM_VERSION"

package_architecture() {
  local target="$1"
  local upstream_architecture="$2"
  local published_architecture="$3"
  local upstream_dmg="$SOURCE_ROOT/dist/macos/CodexPlusPlus-$UPSTREAM_VERSION-macos-$upstream_architecture.dmg"
  local staged_dmg="$STAGE_ROOT/apps/CodexPlusPlus-$UPSTREAM_VERSION-$PATCH_REVISION-macos-$published_architecture.dmg"
  CODEXKIT_COMPATIBILITY_REVISION="$COMPATIBILITY_REVISION" \
  BINARY_DIR="$BUILD_TARGET_ROOT/$target/release" \
    /bin/bash "$SOURCE_ROOT/scripts/installer/macos/package-dmg.sh" \
      "$UPSTREAM_VERSION" "$upstream_architecture"
  [[ -f "$upstream_dmg" && ! -L "$upstream_dmg" ]] \
    || die 66 "packager did not create expected DMG: $upstream_dmg"
  /bin/cp "$upstream_dmg" "$staged_dmg"
}

package_architecture "$ARM_TARGET" arm64 arm64
package_architecture "$X64_TARGET" x64 x64

inspect_dmg_native() {
  local dmg="$1"
  local attachment="$TEMP_ROOT/attach-$RANDOM.plist"
  local mount_point=''
  local index=0
  /usr/bin/hdiutil attach -readonly -nobrowse -noverify -plist "$dmg" > "$attachment"
  while [[ "$index" -lt 32 ]]; do
    mount_point="$(/usr/libexec/PlistBuddy \
      -c "Print :system-entities:$index:mount-point" "$attachment" 2>/dev/null || true)"
    [[ -n "$mount_point" ]] && break
    index=$((index + 1))
  done
  [[ -n "$mount_point" && -d "$mount_point" ]] || die 66 "unable to resolve DMG mount point"
  printf '%s\n' "$mount_point" >> "$MOUNT_POINTS_FILE"
  [[ "$(/usr/bin/find "$mount_point" -maxdepth 1 -type d -name '*.app' \
      | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 2 \
     && -d "$mount_point/Codex++.app" \
     && -d "$mount_point/Codex++ 管理工具.app" ]] \
    || die 66 "Codex++ DMG must contain exactly the launcher and manager apps"

  local application_lines="$TEMP_ROOT/applications-$RANDOM.jsonl"
  local architecture_lines="$TEMP_ROOT/architectures-$RANDOM.txt"
  : > "$application_lines"
  : > "$architecture_lines"
  local app plist bundle version revision executable architectures architecture_json
  for app in "$mount_point/Codex++.app" "$mount_point/Codex++ 管理工具.app"; do
    plist="$app/Contents/Info.plist"
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    revision="$(/usr/libexec/PlistBuddy -c 'Print :CodexKitCompatibilityRevision' "$plist")"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
    [[ -f "$app/Contents/MacOS/$executable" ]] || die 66 "DMG executable is missing"
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
      || die 66 "DMG application signature verification failed"
    architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable" 2>/dev/null)"
    [[ -n "$architectures" ]] || die 66 "DMG application architecture is missing"
    printf '%s\n' $architectures >> "$architecture_lines"
    architecture_json="$(printf '%s\n' $architectures \
      | LC_ALL=C /usr/bin/sort -u | jq -R . | jq -s .)"
    jq -cn \
      --arg bundleIdentifier "$bundle" \
      --arg version "$version" \
      --arg compatibilityRevision "$revision" \
      --argjson architectures "$architecture_json" \
      '{bundleIdentifier:$bundleIdentifier,version:$version,compatibilityRevision:$compatibilityRevision,architectures:$architectures}' \
      >> "$application_lines"
  done
  /usr/bin/hdiutil detach "$mount_point" >/dev/null
  local applications_json all_architectures
  applications_json="$(jq -s . "$application_lines")"
  all_architectures="$(LC_ALL=C /usr/bin/sort -u "$architecture_lines" | jq -R . | jq -s .)"
  jq -cn \
    --arg version "$UPSTREAM_VERSION" \
    --arg compatibilityRevision "$COMPATIBILITY_REVISION" \
    --argjson applications "$applications_json" \
    --argjson architectures "$all_architectures" \
    '{version:$version,compatibilityRevision:$compatibilityRevision,applications:$applications,architectures:$architectures}'
}

inspect_and_validate() {
  local dmg="$1"
  local expected_architecture="$2"
  local inspection="$TEMP_ROOT/inspection-$expected_architecture.json"
  if [[ -n "$APP_INSPECT_BIN" ]]; then
    [[ "$TEST_MODE" == 1 && -x "$APP_INSPECT_BIN" ]] \
      || die 64 "APP_INSPECT_BIN is test-only"
    "$APP_INSPECT_BIN" "$dmg" > "$inspection"
  else
    inspect_dmg_native "$dmg" > "$inspection"
  fi
  jq -e \
    --arg version "$UPSTREAM_VERSION" \
    --arg revision "$COMPATIBILITY_REVISION" \
    --arg architecture "$expected_architecture" '
      .version == $version and
      .compatibilityRevision == $revision and
      (.applications | type == "array" and length == 2) and
      ([.applications[].bundleIdentifier] | sort) ==
        ["com.bigpizzav3.codexplusplus", "com.bigpizzav3.codexplusplus.manager"] and
      all(.applications[];
        .version == $version and
        .compatibilityRevision == $revision and
        (.architectures | index($architecture)) != null
      )
    ' "$inspection" >/dev/null \
    || die 66 "Codex++ $expected_architecture DMG identity or compatibility revision is invalid"
}

inspect_and_validate "$STAGE_ROOT/apps/$arm_name" arm64
inspect_and_validate "$STAGE_ROOT/apps/$x64_name" x86_64

arm_sha="$(/usr/bin/shasum -a 256 "$STAGE_ROOT/apps/$arm_name" | /usr/bin/awk '{print $1}')"
x64_sha="$(/usr/bin/shasum -a 256 "$STAGE_ROOT/apps/$x64_name" | /usr/bin/awk '{print $1}')"
source_sha="$(/usr/bin/shasum -a 256 "$STAGE_ROOT/sources/$source_name" | /usr/bin/awk '{print $1}')"

jq \
  --arg generatedAt "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg version "$UPSTREAM_VERSION" \
  --arg revision "$COMPATIBILITY_REVISION" \
  --arg armPath "apps/$arm_name" \
  --arg x64Path "apps/$x64_name" \
  --arg sourcePath "sources/$source_name" \
  --arg armSHA "$arm_sha" \
  --arg x64SHA "$x64_sha" \
  --arg sourceSHA "$source_sha" \
  --arg armURL "$RELEASE_BASE_URL/$arm_name" \
  --arg x64URL "$RELEASE_BASE_URL/$x64_name" \
  --arg sourceURL "$RELEASE_BASE_URL/$source_name" '
    .generatedAt = $generatedAt |
    .files |= map(
      if .id == "codex-plus-plus-arm64" then
        .version = $version |
        .compatibilityRevision = $revision |
        .relativePath = $armPath |
        .sha256 = $armSHA |
        .sourceURL = $armURL
      elif .id == "codex-plus-plus-x86_64" then
        .version = $version |
        .compatibilityRevision = $revision |
        .relativePath = $x64Path |
        .sha256 = $x64SHA |
        .sourceURL = $x64URL
      elif .id == "codex-plus-plus-source" then
        .version = $version |
        .compatibilityRevision = $revision |
        .relativePath = $sourcePath |
        .sha256 = $sourceSHA |
        .sourceURL = $sourceURL
      else .
      end
    )
  ' "$OUTPUT_ROOT/payload-manifest.json" > "$STAGE_ROOT/payload-manifest.json"

jq -e \
  --arg version "$UPSTREAM_VERSION" \
  --arg revision "$COMPATIBILITY_REVISION" '
    [.files[] | select(.id | startswith("codex-plus-plus-"))] as $codexPlus |
    ($codexPlus | length) == 3 and
    all($codexPlus[]; .version == $version and .compatibilityRevision == $revision)
  ' "$STAGE_ROOT/payload-manifest.json" >/dev/null \
  || die 67 "staged manifest does not describe the complete patched payload set"

/bin/mkdir -p "$OUTPUT_ROOT/apps" "$OUTPUT_ROOT/sources"
for publication in \
  "apps/$arm_name" \
  "apps/$x64_name" \
  "sources/$source_name" \
  "payload-manifest.json"; do
  source_path="$STAGE_ROOT/$publication"
  destination_path="$OUTPUT_ROOT/$publication"
  destination_directory="$(dirname "$destination_path")"
  temporary_path="$destination_directory/.$(basename "$destination_path").codexkit-stage.$$"
  /bin/cp "$source_path" "$temporary_path"
  /bin/mv -f "$temporary_path" "$destination_path"
done

SUPERSEDED_ROOT="$ROOT/dist/superseded-codex-plus-payloads"
while IFS= read -r previous_relative; do
  [[ -n "$previous_relative" ]] || continue
  case "$previous_relative" in
    "apps/$arm_name"|"apps/$x64_name"|"sources/$source_name") continue ;;
    apps/CodexPlusPlus-*|sources/CodexPlusPlus-*) ;;
    *) die 67 "previous Codex++ payload path is unsafe: $previous_relative" ;;
  esac
  previous_path="$OUTPUT_ROOT/$previous_relative"
  if [[ -f "$previous_path" && ! -L "$previous_path" ]]; then
    /bin/mkdir -p "$SUPERSEDED_ROOT/$(dirname "$previous_relative")"
    /bin/mv -f "$previous_path" "$SUPERSEDED_ROOT/$previous_relative"
  elif [[ -e "$previous_path" || -L "$previous_path" ]]; then
    die 67 "previous Codex++ payload is not a regular file: $previous_relative"
  fi
done <<< "$PREVIOUS_CODEX_PLUS_PATHS"

printf 'build-codex-plus-compatibility-payloads: PASS (%s + %s, %s)\n' \
  "$ARM_TARGET" "$X64_TARGET" "$COMPATIBILITY_REVISION"
