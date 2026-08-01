#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-plus-payload-build-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'codex-plus-payload-build-tests: FAIL: %s\n' "$1" >&2
  exit 1
}

archive_line="$(rg -nF 'COPYFILE_DISABLE=1 /usr/bin/tar -czf "$STAGE_ROOT/sources/$source_name"' \
  "$ROOT/scripts/build-codex-plus-compatibility-payloads.sh" | /usr/bin/awk -F: 'NR == 1 { print $1 }')"
last_build_line="$(rg -nF '"$CARGO_BIN" build' \
  "$ROOT/scripts/build-codex-plus-compatibility-payloads.sh" | /usr/bin/awk -F: 'END { print $1 }')"
[[ -n "$archive_line" && -n "$last_build_line" && "$archive_line" -gt "$last_build_line" ]] \
  || fail 'source archive staging must follow Rust checks and both target builds'

SOURCE_FIXTURE="$TEST_ROOT/CodexPlusPlus-1.2.43"
OUTPUT_ROOT="$TEST_ROOT/offline-payloads"
FAKE_BIN="$TEST_ROOT/fake-bin"
CAPTURE_DIR="$TEST_ROOT/capture"
mkdir -p \
  "$SOURCE_FIXTURE/apps/codex-plus-manager" \
  "$SOURCE_FIXTURE/crates/codex-plus-core/tests" \
  "$SOURCE_FIXTURE/scripts/installer/macos" \
  "$OUTPUT_ROOT/apps" \
  "$OUTPUT_ROOT/sources" \
  "$FAKE_BIN" \
  "$CAPTURE_DIR"

printf '%s\n' '[workspace]' > "$SOURCE_FIXTURE/Cargo.toml"
printf '%s\n' 'AGPL fixture' > "$SOURCE_FIXTURE/LICENSE"
printf '%s\n' '{"name":"codex-plus-manager","scripts":{}}' \
  > "$SOURCE_FIXTURE/apps/codex-plus-manager/package.json"
cat > "$SOURCE_FIXTURE/scripts/installer/macos/package-dmg.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
version="$1"
architecture="$2"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$root/dist/macos"
printf 'fixture dmg %s %s %s\n' \
  "$version" "$architecture" "${CODEXKIT_COMPATIBILITY_REVISION:?}" \
  > "$root/dist/macos/CodexPlusPlus-$version-macos-$architecture.dmg"
SH
chmod +x "$SOURCE_FIXTURE/scripts/installer/macos/package-dmg.sh"

(
  cd "$TEST_ROOT"
  tar -czf CodexPlusPlus-v1.2.43.tar.gz CodexPlusPlus-1.2.43
)

cat > "$OUTPUT_ROOT/payload-manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-26T00:00:00Z",
  "files": [
    {
      "id": "codex-plus-plus-arm64",
      "version": "1.2.43",
      "architecture": "arm64",
      "relativePath": "apps/CodexPlusPlus-1.2.43-macos-arm64.dmg",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "sourceURL": "https://example.invalid/upstream-arm64.dmg",
      "format": "dmg",
      "licenseID": "AGPL-3.0-only"
    },
    {
      "id": "codex-plus-plus-x86_64",
      "version": "1.2.43",
      "architecture": "x86_64",
      "relativePath": "apps/CodexPlusPlus-1.2.43-macos-x64.dmg",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "sourceURL": "https://example.invalid/upstream-x64.dmg",
      "format": "dmg",
      "licenseID": "AGPL-3.0-only"
    },
    {
      "id": "codex-plus-plus-source",
      "version": "1.2.43",
      "architecture": "source",
      "relativePath": "sources/CodexPlusPlus-v1.2.43.tar.gz",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "sourceURL": "https://example.invalid/upstream-source.tar.gz",
      "format": "archive",
      "licenseID": "AGPL-3.0-only"
    },
    {
      "id": "model-catalog",
      "version": "2026-07-26",
      "architecture": "any",
      "relativePath": "model-catalog.json",
      "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "sourceURL": "https://example.invalid/model-catalog.json",
      "format": "file"
    }
  ]
}
JSON

cat > "$FAKE_BIN/patch" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'patch\t%s\n' "$*" >> "${CAPTURE_DIR:?}/commands.log"
cat >/dev/null
SH

cat > "$FAKE_BIN/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm\t%s\n' "$*" >> "${CAPTURE_DIR:?}/commands.log"
SH

cat > "$FAKE_BIN/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo\t%s\n' "$*" >> "${CAPTURE_DIR:?}/commands.log"
target=''
previous=''
for argument in "$@"; do
  if [[ "$previous" == --target ]]; then target="$argument"; fi
  previous="$argument"
done
if [[ -n "$target" ]]; then
  binary_root="${CODEX_PLUS_BUILD_SOURCE_ROOT:?}/target/$target/release"
  mkdir -p "$binary_root"
  : > "$binary_root/codex-plus-plus"
  : > "$binary_root/codex-plus-plus-manager"
  chmod +x "$binary_root/codex-plus-plus" "$binary_root/codex-plus-plus-manager"
fi
SH

cat > "$FAKE_BIN/inspect" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  *arm64.dmg) architecture=arm64 ;;
  *x64.dmg) architecture=x86_64 ;;
  *) exit 65 ;;
esac
jq -cn \
  --arg architecture "$architecture" \
  '{
    version:"1.2.43",
    compatibilityRevision:"cross-provider-content-v1",
    applications:[
      {
        bundleIdentifier:"com.bigpizzav3.codexplusplus",
        version:"1.2.43",
        compatibilityRevision:"cross-provider-content-v1",
        architectures:[$architecture]
      },
      {
        bundleIdentifier:"com.bigpizzav3.codexplusplus.manager",
        version:"1.2.43",
        compatibilityRevision:"cross-provider-content-v1",
        architectures:[$architecture]
      }
    ]
  }'
SH
chmod +x "$FAKE_BIN/"*

CAPTURE_DIR="$CAPTURE_DIR" \
TEST_MODE=1 \
SOURCE_ARCHIVE="$TEST_ROOT/CodexPlusPlus-v1.2.43.tar.gz" \
OUTPUT_ROOT="$OUTPUT_ROOT" \
PATCH_BIN="$FAKE_BIN/patch" \
NPM_BIN="$FAKE_BIN/npm" \
CARGO_BIN="$FAKE_BIN/cargo" \
APP_INSPECT_BIN="$FAKE_BIN/inspect" \
bash "$ROOT/scripts/build-codex-plus-compatibility-payloads.sh"

commands="$CAPTURE_DIR/commands.log"
rg -F $'cargo\ttest' "$commands" >/dev/null || fail 'targeted Rust test was not run'
rg -F -- '-p codex-plus-core --test codexkit_cross_provider_content' "$commands" >/dev/null \
  || fail 'cross-provider Rust test was not selected'
rg -F $'cargo\tfmt --all -- --check' "$commands" >/dev/null \
  || fail 'Rust formatting check was not run before packaging'
rg -F $'cargo\ttest --workspace' "$commands" >/dev/null \
  || fail 'workspace Rust tests were not run before packaging'
rg -F -- '--target aarch64-apple-darwin' "$commands" >/dev/null \
  || fail 'arm64 Rust target was not built'
rg -F -- '--target x86_64-apple-darwin' "$commands" >/dev/null \
  || fail 'x86_64 Rust target was not built'
rg -F $'npm\t' "$commands" >/dev/null || fail 'manager frontend commands were not run'

arm_dmg="$OUTPUT_ROOT/apps/CodexPlusPlus-1.2.43-codexkit.1-macos-arm64.dmg"
x64_dmg="$OUTPUT_ROOT/apps/CodexPlusPlus-1.2.43-codexkit.1-macos-x64.dmg"
source_archive="$OUTPUT_ROOT/sources/CodexPlusPlus-v1.2.43-codexkit.1.tar.gz"
[[ -f "$arm_dmg" && -f "$x64_dmg" && -f "$source_archive" ]] \
  || fail 'patched payload set is incomplete'
tar -tzf "$source_archive" | rg -q 'CODEXKIT-PATCH.md$' \
  || fail 'patched source provenance is missing'
source_extract="$TEST_ROOT/source-extract"
mkdir -p "$source_extract"
tar -xzf "$source_archive" -C "$source_extract"
provenance_file="$source_extract/CodexPlusPlus-1.2.43/CODEXKIT-PATCH.md"
expected_patch_sha="$(shasum -a 256 "$ROOT/patches/CodexPlusPlus/v1.2.43-cross-provider-history.patch" | awk '{print $1}')"
rg -F "Patch SHA-256: $expected_patch_sha" "$provenance_file" >/dev/null \
  || fail 'source provenance patch SHA is stale'
rg -F 'Remove `style` from the macOS Dream Skin root MutationObserver filters' "$provenance_file" >/dev/null \
  || fail 'source provenance omits the Dream Skin observer compatibility fix'
jq -e '
  [.files[] | select(.id | startswith("codex-plus-plus-"))]
  | length == 3
  and all(.[]; .version == "1.2.43")
  and all(.[]; .compatibilityRevision == "cross-provider-content-v1")
' "$OUTPUT_ROOT/payload-manifest.json" >/dev/null \
  || fail 'patched manifest metadata is invalid'

WRONG_SOURCE="$TEST_ROOT/CodexPlusPlus-1.2.42"
mkdir -p "$WRONG_SOURCE"
printf '%s\n' '[workspace]' > "$WRONG_SOURCE/Cargo.toml"
(
  cd "$TEST_ROOT"
  tar -czf CodexPlusPlus-v1.2.42.tar.gz CodexPlusPlus-1.2.42
)
set +e
CAPTURE_DIR="$CAPTURE_DIR" \
TEST_MODE=1 \
SOURCE_ARCHIVE="$TEST_ROOT/CodexPlusPlus-v1.2.42.tar.gz" \
OUTPUT_ROOT="$OUTPUT_ROOT" \
PATCH_BIN="$FAKE_BIN/patch" \
NPM_BIN="$FAKE_BIN/npm" \
CARGO_BIN="$FAKE_BIN/cargo" \
APP_INSPECT_BIN="$FAKE_BIN/inspect" \
bash "$ROOT/scripts/build-codex-plus-compatibility-payloads.sh" \
  > "$TEST_ROOT/wrong-version.log" 2>&1
wrong_status=$?
set -e
[[ "$wrong_status" -eq 65 ]] || fail 'wrong source version was not rejected'
rg -F 'source archive must contain CodexPlusPlus-1.2.43' "$TEST_ROOT/wrong-version.log" >/dev/null \
  || fail 'wrong source version explanation is missing'

printf '%s\n' 'codex-plus-payload-build-tests: PASS'
