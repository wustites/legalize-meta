#!/usr/bin/env bash
# tools/check-offline.sh — 校验构建链路完全离线，且文本、清单、工具与构建产物一致
#
# 九项检查：
#   1. 构建脚本无取网络命令
#   2. 构建脚本无网络地址
#   3. 文本清单与文本文件齐备
#   4. 清单格式
#   5. 文本拆分/重组、目录、空标题/空小节
#   6. 条文编号完整性（全文连续，区分真正的多版本文本）
#   7. 时区与 IANA 一致
#   8. 现场构建 8 个区域并校验日期标签
#   9. 安全构建与条文审计的回归测试

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
status=0

echo "== 1. 构建脚本中不得出现取网络的命令 =="
PATTERN='curl|wget|Invoke-WebRequest|Invoke-RestMethod|WebClient|urllib|requests\.|http\.client|git[[:space:]]+(clone|fetch|pull|ls-remote|remote)'
hits="$(grep -nEi "$PATTERN" */build.sh */build.ps1 tools/build-core.sh tools/build-core.ps1 2>/dev/null || true)"
if [ -n "$hits" ]; then
  echo "!! 构建脚本出现取网络的命令："
  echo "$hits" | sed 's/^/     /'
  status=1
else
  echo "  OK：8 组区域入口与两个构建核心均无取网络命令"
fi

echo
echo "== 2. 构建脚本中不得出现网络地址 =="
urls="$(grep -nE 'https?://' */build.sh */build.ps1 tools/build-core.sh tools/build-core.ps1 2>/dev/null || true)"
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
python3 tools/check-manifest.py || status=1

echo
echo "== 5. 文本拆分/重组与结构校验 =="
python3 tools/verify-corpus.py || status=1

echo
echo "== 6. 条文编号完整性 =="
python3 tools/audit-articles.py || status=1

echo
echo "== 7. 时区与 IANA 校验 =="
python3 tools/verify-tz.py --all || status=1

echo
echo "== 8. 构建样例并校验日期标签 =="
SAMPLE="$(mktemp -d /tmp/legalize-check.XXXXXX)"
trap 'rm -rf "$SAMPLE"' EXIT
for d in cn hk tw mo jp kr kp vn; do
  mkdir -p "$SAMPLE/$d"
  if ! bash "$d/build.sh" "$SAMPLE/$d" > "$SAMPLE/$d.log" 2>&1; then
    echo "!! $d 构建失败："; tail -5 "$SAMPLE/$d.log"; status=1
  fi
done
[ "$status" -eq 0 ] && echo "  8 个区域构建成功" || true
python3 tools/verify-tags.py "$SAMPLE" || status=1

echo
echo "== 9. 安全构建与条文审计回归测试 =="
bash tools/test-build-safety.sh || status=1
python3 tools/test-audit.py || status=1

echo
if [ "$status" -eq 0 ]; then
  echo "检查通过：构建离线、文本与清单齐备、结构/编号/时区正确、日期标签正确、安全回归通过。"
else
  echo "检查未通过。"
fi
exit "$status"
