#!/usr/bin/env bash
# tools/check-offline.sh — 校验构建链路完全离线，且文本与清单齐备
#
# 宪制法律文本已随本仓库保存在 <region>/texts/ 下，构建过程必须不访问网络。
# 本脚本扫描所有 build.sh / build.ps1，出现任何取网络的手段即判失败。
# 文本的更新是维护者操作（tools/update-sources.sh），不在构建链路上。

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
status=0

echo "== 1. 构建脚本中不得出现取网络的命令 =="
PATTERN='curl|wget|Invoke-WebRequest|Invoke-RestMethod|WebClient|urllib|requests\.|http\.client|git[[:space:]]+(clone|fetch|pull|ls-remote|remote)'
hits="$(grep -nEi "$PATTERN" */build.sh */build.ps1 2>/dev/null || true)"
if [ -n "$hits" ]; then
  echo "!! 构建脚本出现取网络的命令："
  echo "$hits" | sed 's/^/     /'
  status=1
else
  echo "  OK：8 个 build.sh 与 8 个 build.ps1 均无取网络命令"
fi

echo
echo "== 2. 构建脚本中不得出现网络地址 =="
urls="$(grep -nE 'https?://' */build.sh */build.ps1 2>/dev/null || true)"
if [ -n "$urls" ]; then
  echo "!! 构建脚本中出现 URL："
  echo "$urls" | sed 's/^/     /'
  status=1
else
  echo "  OK：无 URL"
fi

echo
echo "== 3. 文本清单与文本文件必须齐备 =="
for d in cn hk tw mo jp kr kp vn; do
  m="$d/texts/manifest.tsv"
  if [ ! -f "$m" ]; then echo "!! $d 缺少 $m"; status=1; continue; fi
  n="$(awk -F'\t' '!/^#/ && NF {n++} END {print n+0}' "$m")"
  missing=0
  while IFS=$'\t' read -r branch seq file rest; do
    case "${branch:-}" in ''|'#'*) continue ;; esac
    [ -s "$d/texts/$file" ] || { echo "!! $d/texts/$file 缺失或为空"; missing=1; }
  done < "$m"
  [ "$missing" -eq 0 ] || status=1
  printf '  %-3s %2d 条清单，文本齐备\n' "$d" "$n"
done

echo
echo "== 4. 清单格式校验 =="
python3 "$(dirname "$0")/check-manifest.py" || status=1

echo
if [ "$status" -eq 0 ]; then
  echo "检查通过：构建链路完全离线，文本与清单齐备。"
else
  echo "检查未通过。"
fi
exit "$status"
