#!/usr/bin/env bash
set -euo pipefail
umask 077

OPENAI_ARM_URL='https://persistent.oaistatic.com/codex-app-prod/Codex.dmg'
OPENAI_X64_URL='https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg'
CODEX_PLUS_REPOSITORY='BigPizzaV3/CodexPlusPlus'
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
    https://persistent.oaistatic.com/*|https://github.com/*|https://objects.githubusercontent.com/*|https://*.githubusercontent.com/*) ;;
    *) printf '拒绝不受信任的下载源：%s\n' "$url" >&2; exit 65 ;;
  esac
  /usr/bin/curl --fail --location --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$destination" "$url"
  [[ -s "$destination" ]] || { printf '下载文件为空：%s\n' "$url" >&2; exit 65; }
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

printf '正在查询 Codex++ GitHub Release…\n'
release_json="$WORK_ROOT/codex-plus.json"
download "https://api.github.com/repos/$CODEX_PLUS_REPOSITORY/releases/latest" "$release_json"
version="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"].lstrip("v"))' "$release_json")"
arch="$(/usr/bin/uname -m)"
[[ "$arch" == x86_64 ]] && asset_arch=x64 || asset_arch=arm64
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
codex_plus_mount="$(mount_dmg "$codex_plus_dmg")"
for app_name in 'Codex++.app' 'Codex++ 管理工具.app'; do
  app="$codex_plus_mount/$app_name"
  [[ -d "$app" ]] || { printf 'Codex++ DMG 中缺少 %s\n' "$app_name" >&2; exit 66; }
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/sudo /usr/bin/ditto "$app" "/Applications/$app_name"
done
/usr/bin/hdiutil detach "$codex_plus_mount" >/dev/null

printf '正在安装科研技能合集…\n'
script_dir="$(cd "$(dirname "$0")" && pwd)"
UNICODEX_SKILL_MANIFEST="$script_dir/skills/collections.json" \
  "$script_dir/install-skill-collections.sh"

printf 'Uni-codex 安装完成。\n'
