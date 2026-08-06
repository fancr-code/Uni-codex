#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${UNICODEX_SKILL_MANIFEST:-$SCRIPT_ROOT/../skills/collections.json}"
BUNDLE_ROOT="${UNICODEX_SKILL_BUNDLE:-}"
DESTINATION="${UNICODEX_SKILL_DESTINATION:-$HOME/.codex/skills}"
PREPARE_BUNDLE="${UNICODEX_SKILL_PREPARE_BUNDLE:-0}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uni-codex-skills.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
/bin/mkdir -p "$DESTINATION"

total=0
while IFS=$'\t' read -r id repository commit skills_root; do
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 65
  if [[ -n "$BUNDLE_ROOT" ]]; then
    repo_root="$BUNDLE_ROOT/$id"
    source_root="$repo_root/skills"
  else
    archive="$WORK/$id.zip"
    /usr/bin/curl --fail --location --retry 3 \
      "https://codeload.github.com/$repository/zip/$commit" -o "$archive"
    /usr/bin/ditto -x -k "$archive" "$WORK/$id"
    repo_root="$(/usr/bin/find "$WORK/$id" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    source_root="$repo_root/$skills_root"
  fi
  [[ -d "$source_root" ]] || { printf '缺少技能合集：%s\n' "$id" >&2; exit 66; }
  collection_destination="$DESTINATION"
  [[ "$PREPARE_BUNDLE" == 1 ]] && collection_destination="$DESTINATION/$id/skills"
  /bin/mkdir -p "$collection_destination"
  while IFS= read -r skill_file; do
    skill_dir="${skill_file%/SKILL.md}"
    name="${skill_dir##*/}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 65
    target="$collection_destination/$name"
    if [[ -e "$target" && ! -f "$target/.uni-codex-collection.json" ]]; then
      printf '保留用户已有技能：%s\n' "$name"
      continue
    fi
    /bin/rm -rf "$target"
    /usr/bin/ditto "$skill_dir" "$target"
    printf '{"collection":"%s","repository":"%s","commit":"%s"}\n' \
      "$id" "$repository" "$commit" > "$target/.uni-codex-collection.json"
    total=$((total + 1))
  done < <(/usr/bin/find "$source_root" -type f -name SKILL.md | /usr/bin/sort)
  license="$(/usr/bin/find "$repo_root" -mindepth 1 -maxdepth 1 -type f \( -name 'LICENSE*' -o -name 'COPYING*' \) -print -quit)"
  [[ -f "$license" ]] || { printf '缺少许可证：%s\n' "$id" >&2; exit 66; }
  if [[ "$PREPARE_BUNDLE" == 1 ]]; then
    license_target="$DESTINATION/$id/LICENSE"
  else
    license_target="$DESTINATION/.uni-codex-licenses/$id/LICENSE"
  fi
  /bin/mkdir -p "${license_target%/*}"
  /bin/cp "$license" "$license_target"
done < <(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1]))['collections']:
    print(item['id'], item['repository'], item['commit'], item['skillsRoot'], sep='\t')
PY
)
printf '已安装 %s 个 Codex skills。\n' "$total"
