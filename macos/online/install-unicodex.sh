#!/usr/bin/env bash
set -euo pipefail
umask 077

OPENAI_ARM_URL='https://persistent.oaistatic.com/codex-app-prod/Codex.dmg'
OPENAI_X64_URL='https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg'
CODEX_PLUS_REPOSITORY='BigPizzaV3/CodexPlusPlus'
DREAM_SKIN_VERSION='1.5.11'
DREAM_SKIN_URL="https://github.com/Fei-Away/Codex-Dream-Skin/releases/download/v${DREAM_SKIN_VERSION}/CodexDreamSkin-v${DREAM_SKIN_VERSION}.dmg"
DREAM_SKIN_SHA256='755ed9b8189193ec4be3d69c6625a10910ea8b33718465b2f1e000c5ccbdcba1'
DREAM_SKIN_THEME_IDS=(
  'ver_ab667004dad5bfec326d'
  'ver_6fac938806981a73cb51'
  'ver_f2b255d03e6ac7f91ada'
  'ver_a5a7c185610e6ccee928'
  'ver_4367ae5c3ef91daf8efa'
  'ver_1f00673afb67fd30f91e'
  'ver_5c32fdc7b685ede6fd07'
  'ver_2b3bc79cfe2e5141c7a2'
  'ver_4e1216c88d5cb2a39c53'
  'ver_dd3882239f93b014ba65'
)
DREAM_SKIN_THEME_SHA256=(
  'b2892300bdfb1229a092c140c5fd5de41fa27b97db6ec7e827c3ae0f9d75af44'
  '00f6adab28a022bad16c5ff8139dd3b11a59415ad7912034dff372b68baa56ef'
  'fcbdc5efebbf43db7cdbbe9ae213b71da6daa33ef59e36e1b8567a6a20cabdc0'
  '607c5c6bc6989aa5113446a5beac3fdecff4dcc8123b430c242b9827ab2c0cd5'
  '5b7e72fa46f9da7a42be45a9689342c1506158e19f40a8c8fe9f747b707195cc'
  '058ab04d118bd66da7be082ebd8dba81dd0a285e6b68b356287ff870caff9ff9'
  '2c820302ab365aa364b8aed2c6e5395ba3e1f6baec9d06ee04c68c6e699e8b67'
  'a1c7e626121cf32693f2ec46dceaa8e1592bdb054c25a9ae50daf87710223996'
  'cd6c95bfe5bf6079ef450c3c552ad0f52fafe594aa16196ce8645d9ad7916e67'
  '20bd5ef48ad62ebbf6e35810399c7b86986a7594468a8b507188a13dbbec5b3c'
)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uni-codex.XXXXXX")"
MOUNTS=()

cleanup() {
  local mount
  for mount in "${MOUNTS[@]}"; do
    /usr/bin/hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  done
  /bin/rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

download() {
  local url="$1" destination="$2"
  case "$url" in
    https://persistent.oaistatic.com/*|https://github.com/*|https://objects.githubusercontent.com/*|https://*.githubusercontent.com/*|https://api.dreamskin.cc/*) ;;
    *) printf '拒绝不受信任的下载源：%s\n' "$url" >&2; exit 65 ;;
  esac
  /usr/bin/curl --fail --location --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$destination" "$url"
  [[ -s "$destination" ]] || { printf '下载文件为空：%s\n' "$url" >&2; exit 65; }
}

download_verified() {
  local url="$1" destination="$2" expected="$3"
  download "$url" "$destination"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || { printf 'SHA-256 校验失败：%s\n' "$url" >&2; exit 65; }
}

choose_dream_skin() {
  if [[ -n "${UNICODEX_DREAM_SKIN_PRESET:-}" ]]; then
    DREAM_SKIN_PRESET="$UNICODEX_DREAM_SKIN_PRESET"
  else
    printf '\n选择预设皮肤：\n  1) Gothic Void Crusade（推荐）\n  2) DreamSkin.cc 主题库（安装时连接 API）\n  3) 官方默认外观（不启用 Dream Skin）\n请输入编号 [1]: '
    read -r choice || choice=1
    case "$choice" in
      2) DREAM_SKIN_PRESET='gallery' ;;
      3) DREAM_SKIN_PRESET='none' ;;
      *) DREAM_SKIN_PRESET='preset-gothic-void-crusade' ;;
    esac
  fi
  case "$DREAM_SKIN_PRESET" in
    preset-gothic-void-crusade|gallery|none) ;;
    *) printf '不支持的 Dream Skin 预设：%s\n' "$DREAM_SKIN_PRESET" >&2; exit 64 ;;
  esac
}

seed_downloaded_theme() {
  local archive="$1"
  local themes_root="$HOME/Library/Application Support/CodexDreamSkinStudio/themes"
  /usr/bin/python3 - "$archive" "$themes_root" <<'PY'
import json
import pathlib
import shutil
import sys
import tempfile
import zipfile

archive = pathlib.Path(sys.argv[1]).resolve()
themes_root = pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as package:
    entries = [item for item in package.infolist() if not item.is_dir()]
    if len(entries) > 32:
        raise SystemExit("theme archive has too many entries")
    for item in entries:
        name = pathlib.PurePosixPath(item.filename)
        if name.is_absolute() or ".." in name.parts or len(name.parts) != 1:
            raise SystemExit("theme archive contains an unsafe path")
    try:
        manifest = json.loads(package.read("manifest.json"))
    except Exception as error:
        raise SystemExit(f"invalid theme manifest: {error}")
    theme_id = str(manifest.get("themeId", ""))
    if not theme_id or not all(c.isalnum() or c in "._-" for c in theme_id):
        raise SystemExit("invalid theme id")
    if "macos" not in manifest.get("platforms", []):
        raise SystemExit("theme does not support macOS")
    required = {"manifest.json", "theme.json", "theme.css"}
    if not required.issubset({item.filename for item in entries}):
        raise SystemExit("theme archive is missing required files")
    themes_root.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=f".{theme_id}.", dir=themes_root))
    try:
        for item in entries:
            destination = temporary / pathlib.PurePosixPath(item.filename).name
            with package.open(item) as source, destination.open("wb") as target:
                shutil.copyfileobj(source, target)
        destination = themes_root / theme_id
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
PY
}

download_community_themes() {
  local index id archive
  local themes_root="$HOME/Library/Application Support/CodexDreamSkinStudio/themes"
  /bin/mkdir -p "$themes_root"
  for index in "${!DREAM_SKIN_THEME_IDS[@]}"; do
    id="${DREAM_SKIN_THEME_IDS[$index]}"
    archive="$WORK_ROOT/$id.zip"
    download_verified \
      "https://api.dreamskin.cc/v1/themes/$id/download" \
      "$archive" "${DREAM_SKIN_THEME_SHA256[$index]}"
    seed_downloaded_theme "$archive"
  done
  printf '已下载并预装 %d 套 DreamSkin.cc 精选主题。\n' "${#DREAM_SKIN_THEME_IDS[@]}"
}

mount_dmg() {
  local dmg="$1" plist="$WORK_ROOT/mount-$RANDOM.plist" mount=''
  /usr/bin/hdiutil attach -readonly -nobrowse -plist "$dmg" > "$plist"
  local index=0
  while [[ $index -lt 32 ]]; do
    mount="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$plist" 2>/dev/null || true)"
    [[ -n "$mount" ]] && break
    index=$((index + 1))
  done
  [[ -d "$mount" ]] || { printf '无法挂载 DMG\n' >&2; exit 66; }
  MOUNTS+=("$mount")
  printf '%s' "$mount"
}

install_app_from_dmg() {
  local dmg="$1" expected_name="$2" mount app
  mount="$(mount_dmg "$dmg")"
  app="$mount/$expected_name"
  [[ -d "$app" ]] || { printf 'DMG 中缺少 %s\n' "$expected_name" >&2; exit 66; }
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/sudo /usr/bin/ditto "$app" "/Applications/$expected_name"
  /usr/bin/hdiutil detach "$mount" >/dev/null
}

case "$(/usr/bin/uname -m)" in
  arm64) openai_url="$OPENAI_ARM_URL" ;;
  x86_64) openai_url="$OPENAI_X64_URL" ;;
  *) printf '不支持的 macOS 架构\n' >&2; exit 64 ;;
esac

printf '正在下载 OpenAI 官方 Codex 桌面应用…\n'
openai_dmg="$WORK_ROOT/Codex.dmg"
download "$openai_url" "$openai_dmg"
install_app_from_dmg "$openai_dmg" 'ChatGPT.app'

arch="$(/usr/bin/uname -m)"
[[ "$arch" == x86_64 ]] && asset_arch=x64 || asset_arch=arm64
BUNDLED_CODEX_PLUS_DMG="$SCRIPT_DIR/codex-plus-plus/CodexPlusPlus-$asset_arch.dmg"
if [[ -s "$BUNDLED_CODEX_PLUS_DMG" ]]; then
  codex_plus_dmg="$BUNDLED_CODEX_PLUS_DMG"
  printf '使用安装包内置的 Codex++ (%s)…\n' "$asset_arch"
else
  printf '安装包未包含 Codex++，正在查询官方 GitHub Release…\n'
  release_json="$WORK_ROOT/codex-plus.json"
  download "https://api.github.com/repos/$CODEX_PLUS_REPOSITORY/releases/latest" "$release_json"
  version="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"].lstrip("v"))' "$release_json")"
  asset_name="CodexPlusPlus-$version-macos-$asset_arch.dmg"
  asset_url="$(/usr/bin/python3 - "$release_json" "$asset_name" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
matches = [a['browser_download_url'] for a in data['assets'] if a['name'] == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit('Codex++ release asset missing or ambiguous')
print(matches[0])
PY
)"
  codex_plus_dmg="$WORK_ROOT/$asset_name"
  download "$asset_url" "$codex_plus_dmg"
fi
codex_plus_mount="$(mount_dmg "$codex_plus_dmg")"
for app_name in 'Codex++.app' 'Codex++ 管理工具.app'; do
  app="$codex_plus_mount/$app_name"
  [[ -d "$app" ]] || { printf 'Codex++ DMG 中缺少 %s\n' "$app_name" >&2; exit 66; }
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/sudo /usr/bin/ditto "$app" "/Applications/$app_name"
done
/usr/bin/hdiutil detach "$codex_plus_mount" >/dev/null

choose_dream_skin
if [[ "$DREAM_SKIN_PRESET" != 'none' ]]; then
  printf '正在安装 Codex Dream Skin，并下载 10 套 DreamSkin.cc 精选主题…\n'
  dream_skin_dmg="$WORK_ROOT/CodexDreamSkin-v${DREAM_SKIN_VERSION}.dmg"
  download_verified "$DREAM_SKIN_URL" "$dream_skin_dmg" "$DREAM_SKIN_SHA256"
  install_app_from_dmg "$dream_skin_dmg" 'CodexDreamSkin.app'
  download_community_themes
  [[ "$DREAM_SKIN_PRESET" == 'gallery' ]] && /usr/bin/open 'https://dreamskin.cc/gallery' || true
else
  printf '保留官方默认外观。\n'
fi
printf '正在安装科研技能合集…\n'
UNICODEX_SKILL_MANIFEST="$SCRIPT_DIR/skills/collections.json" \
  "$SCRIPT_DIR/install-skill-collections.sh"

printf 'Uni-codex 安装完成。\n'
