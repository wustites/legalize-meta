#!/usr/bin/env bash
# tools/build-core.sh — 所有法域共用的构建核心（离线）
#
# 用法:
#   bash tools/build-core.sh <区域> <目标Git仓库> [--force]
#   bash <区域>/build.sh <目标Git仓库> [--force]      # 区域 wrapper
#
# 安全约定：
#   * 目标必须显式给出；拒绝当前目录、元仓库本身、元仓库的上级目录、元仓库内部路径。
#   * 目标非空时必须加 --force；--force 会替换目标内容（保留 .git/config）。
#   * 先在与目标同级的临时目录里完整构建，成功后才替换目标；构建失败不会破坏旧仓库。
#   * 生成仓库只有一个根提交；重复构建不会在旧根提交上叠加。
#
# 本脚本不访问网络：法律文本全部随仓库保存在 <区域>/texts/ 下，
# 由 <区域>/texts/manifest.tsv 描述分支、日期、时区与提交信息。
#
# 提交时间戳：
#   1970-01-01 及以后 —— 写入该日「当地 0 点」这一瞬间，对象里的偏移取 manifest 声明值。
#   1970-01-01 之前   —— 统一写入 unix 0（Git 无法表示负 epoch），真实日期由日期标签承载。

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
用法: build-core.sh <区域> <目标Git仓库> [--force]

  <区域>        cn | hk | tw | mo | jp | kr | kp | vn
  <目标仓库>    要生成/重建的 Git 仓库路径（不能是当前目录或元仓库内部）
  --force       目标非空时允许替换（会保留 .git/config）

示例:
  bash cn/build.sh /tmp/legalize-cn
  bash cn/build.sh /tmp/legalize-cn --force
EOF
}

die() { echo "[!] $*" >&2; exit 1; }
log() { echo "[*] $*"; }
ok()  { echo "  -> $*"; }
warn(){ echo "[!] $*" >&2; }

if [ "$#" -lt 2 ]; then usage; exit 2; fi

REGION="$1"
TARGET_ARG="$2"
shift 2

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] 未知参数：$a" >&2; usage; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION_DIR="$ROOT/$REGION"
TEXTS_DIR="$REGION_DIR/texts"
MANIFEST="$TEXTS_DIR/manifest.tsv"
REGIONS_TSV="$ROOT/tools/regions.tsv"
README_TPL="$ROOT/tools/output-README.template.md"
NOTICE="$ROOT/NOTICE.md"

[ -f "$MANIFEST" ] || die "找不到文本清单：$MANIFEST"
[ -f "$REGION_DIR/.gitignore" ] || die "缺少 $REGION_DIR/.gitignore"
[ -f "$REGION_DIR/LICENSE" ] || die "缺少 $REGION_DIR/LICENSE"
[ -f "$REGIONS_TSV" ] || die "缺少区域表：$REGIONS_TSV"
[ -f "$README_TPL" ] || die "缺少产物 README 模板：$README_TPL"
[ -f "$NOTICE" ] || die "缺少 NOTICE.md：$NOTICE"
command -v python3 >/dev/null 2>&1 || die "需要 python3（用于计算提交时间戳与解析路径）"

REGION_NAME="$(awk -F'\t' -v r="$REGION" '$1 == r { print $2; exit }' "$REGIONS_TSV")"
[ -n "$REGION_NAME" ] || die "未知区域：$REGION（见 tools/regions.tsv）"

# ---------------------------------------------------------------- 目标路径与安全检查
# 用 Python 解析绝对路径（macOS 的 realpath 没有 -m；这里也顺便解析符号链接）。
TARGET="$(python3 - "$TARGET_ARG" <<'PY'
import os, sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
)" || die "无法解析目标路径：$TARGET_ARG"
[ -n "$TARGET" ] || die "目标路径为空"

[ "$TARGET" != "/" ] || die "拒绝把根目录作为目标"
[ "$TARGET" != "$ROOT" ] || die "拒绝把元仓库本身作为目标"
case "$TARGET" in
  "$ROOT"/*) die "目标不能位于元仓库内部：$TARGET" ;;
esac
case "$ROOT" in
  "$TARGET"/*) die "目标不能是元仓库的上级目录：$TARGET" ;;
esac
case "$(pwd -P)" in
  "$TARGET"|"$TARGET"/*) die "当前工作目录位于目标内；请从目标外运行并传入明确路径" ;;
esac
# 明确拒绝系统/临时目录与 HOME 的上级，避免 --force 误伤。
case "$TARGET" in
  /|/tmp|/var|/var/tmp|/private|/private/tmp|/private/var|/private/var/tmp|/usr|/etc|/opt|/home|/Users|/root|/System|/Library|/Applications)
    die "拒绝把系统/临时目录作为目标：$TARGET" ;;
esac
[ "$(dirname "$TARGET")" != "/" ] || die "拒绝把文件系统顶层目录作为目标：$TARGET"
case "${HOME:-}" in
  "$TARGET"|"$TARGET"/*) die "目标不能是 HOME 或其上级：$TARGET" ;;
esac
for protected in "${TMPDIR:-}" "${TMP:-}" "${TEMP:-}"; do
  [ -n "$protected" ] || continue
  case "$protected" in
    "$TARGET"|"$TARGET"/*) die "目标不能是临时目录或其上级：$TARGET" ;;
  esac
done

if [ -e "$TARGET" ]; then
  [ -d "$TARGET" ] || die "目标不是目录：$TARGET"
  # 裸仓库没有 .git/，避免把它的 HEAD/config 当成普通文件替换掉
  if [ -f "$TARGET/HEAD" ] && [ ! -d "$TARGET/.git" ]; then
    die "不支持把裸 Git 仓库作为目标：$TARGET"
  fi
  if [ -n "$(ls -A "$TARGET" 2>/dev/null | head -n 1)" ]; then
    [ "$FORCE" -eq 1 ] || die "目标非空：$TARGET
       确认替换请加 --force（会替换该目录内容，保留 .git/config）"
  fi
fi

PARENT="$(dirname "$TARGET")"
[ -d "$PARENT" ] || mkdir -p "$PARENT" || die "无法创建父目录：$PARENT"
[ -w "$PARENT" ] || die "父目录不可写：$PARENT"

# ---------------------------------------------------------------- 临时构建目录
TMPROOT="$(mktemp -d "$PARENT/.legalize-build.XXXXXX")" || die "无法创建临时目录（父目录：$PARENT）"
BUILD="$TMPROOT/repo"
BACKUP="$PARENT/.legalize-old.$$.$RANDOM"
cleanup() {
  # 如果替换过程中被打断，尽量把旧目标放回去。
  if [ -n "${BACKUP:-}" ] && [ -e "$BACKUP" ] && [ ! -e "$TARGET" ]; then
    mv "$BACKUP" "$TARGET" 2>/dev/null || true
  fi
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

mkdir -p "$BUILD"

# ---------------------------------------------------------------- 提交与时间戳
GIT_NAME="$(git config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config user.email 2>/dev/null || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

# "<日期> <时区>" -> "<epoch> <时区>"；1970 前统一写 "0 +0000"。
# 用 Python 计算，避免依赖 GNU date -d（macOS 自带 BSD date 不支持）。
commit_stamp() {
  python3 - "$1" "$2" <<'PY'
import datetime, sys
d, tz = sys.argv[1], sys.argv[2]
if len(tz) != 5 or tz[0] not in '+-' or not tz[1:].isdigit():
    raise SystemExit('时区格式不对：%s' % tz)
sign = -1 if tz[0] == '-' else 1
off = sign * (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60)
dt = datetime.datetime.strptime(d, '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
e = int(dt.timestamp()) - off
print('0 +0000' if e < 0 else '%d %s' % (e, tz))
PY
}

mk_commit() {  # $1="<epoch> <tz>" $2=message -> sha
  local stamp="$1" msg="$2" out
  # 不用 -q：失败时把 git 的错误留给用户看。
  if ! out="$(GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="@$stamp" \
              GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="@$stamp" \
              git commit --no-verify -m "$msg" 2>&1)"; then
    warn "提交失败（$stamp）：$msg"
    [ -n "$out" ] && echo "$out" >&2
    return 1
  fi
  git rev-parse HEAD
}

tag_for() {  # $1=branch $2=date
  if [ "$1" = "main" ]; then printf '%s' "$2"; else printf '%s-%s' "$2" "$1"; fi
}

render_readme() {
  local rows commits
  rows="$(awk -F'\t' '!/^#/ && NF { n++ } END { print n + 0 }' "$MANIFEST")"
  commits="$(awk -F'\t' '!/^#/ && NF { k = $1 "\t" $2; if (!(k in seen)) { seen[k] = 1; n++ } } END { print n + 0 }' "$MANIFEST")"
  python3 - "$README_TPL" "$REGION" "$REGION_NAME" "$rows" "$commits" <<'PY'
import pathlib, sys
tpl, region, name, rows, commits = sys.argv[1:6]
text = pathlib.Path(tpl).read_text(encoding='utf-8')
for key, value in {
    '{{REGION}}': region,
    '{{REGION_NAME}}': name,
    '{{TEXT_COUNT}}': rows,
    '{{COMMIT_COUNT}}': commits,
}.items():
    text = text.replace(key, value)
sys.stdout.write(text)
PY
}

# ---------------------------------------------------------------- 构建
log "=== legalize-$REGION 宪制历史构建（离线，不访问网络） ==="
log "区域: $REGION_NAME"
log "目标仓库: $TARGET"
log "文本清单: $MANIFEST"
[ "$FORCE" -eq 1 ] && log "模式: --force（完成后替换目标）"
echo

cd "$BUILD"
git init -q
git symbolic-ref HEAD refs/heads/main
git config core.autocrlf false
git config core.quotepath false

cp "$REGION_DIR/.gitignore" .gitignore
cp "$REGION_DIR/LICENSE" LICENSE
cp "$NOTICE" NOTICE.md
render_readme > README.md
git add .

first_date="$(awk -F'\t' '!/^#/ && NF { print $4; exit }' "$MANIFEST")"
first_tz="$(awk -F'\t' '!/^#/ && NF { print $5; exit }' "$MANIFEST")"
[ -n "$first_date" ] || die "清单为空：$MANIFEST"
first_stamp="$(commit_stamp "$first_date" "$first_tz")"
INIT="$(mk_commit "$first_stamp" "Initial commit")"
ok "根提交 $INIT（$first_date -> 时间戳 $first_stamp）"

branch="" seq=""
g_branch="" g_seq="" g_date="" g_tz="" g_msg="" g_stamp=""
prev="" prev_branch="" prev_seq=""
declare -a g_files=() g_outs=()

commit_group() {
  [ ${#g_files[@]} -eq 0 ] && return 0
  local parent="$INIT" i src dst tag
  if [ "$g_branch" = "$prev_branch" ]; then
    parent="$prev"
  fi
  git checkout -q -B "$g_branch" "$parent"
  for i in "${!g_files[@]}"; do
    src="$TEXTS_DIR/${g_files[$i]}"
    dst="${g_outs[$i]}"
    [ -f "$src" ] || die "缺少文本文件：texts/${g_files[$i]}"
    [ -s "$src" ] || die "文本文件为空：texts/${g_files[$i]}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    git add "$dst"
  done
  prev="$(mk_commit "$g_stamp" "$g_msg")"

  tag="$(tag_for "$g_branch" "$g_date")"
  if git show-ref --verify --quiet "refs/tags/$tag"; then
    die "标签重名：$tag（$g_branch #$g_seq $g_date）"
  fi
  git update-ref "refs/tags/$tag" "$prev"

  prev_branch="$g_branch"
  prev_seq="$g_seq"
  ok "$(printf '%-12s #%-2s %-26s %-24s %s' "$g_branch" "$g_seq" "$tag" "$g_stamp" "${g_msg:0:32}")"
  g_files=()
  g_outs=()
}

while IFS=$'\t' read -r r_branch r_seq r_file r_date r_tz r_out r_msg; do
  case "$r_branch" in ''|\#*) continue ;; esac
  if [ "$r_branch" != "$branch" ] || [ "$r_seq" != "$seq" ]; then
    commit_group
    branch="$r_branch"; seq="$r_seq"
    g_branch="$r_branch"; g_seq="$r_seq"; g_date="$r_date"; g_tz="$r_tz"; g_msg="$r_msg"
    g_stamp="$(commit_stamp "$r_date" "$r_tz")"
  fi
  g_files+=("$r_file")
  g_outs+=("$r_out")
done < "$MANIFEST"
commit_group

git show-ref --verify --quiet refs/heads/main || die "清单没有生成 main 分支"
git checkout -q main
git symbolic-ref HEAD refs/heads/main
[ -z "$(git status --porcelain)" ] || die "构建后工作区不干净"

# ---------------------------------------------------------------- 替换目标
# 保留目标原有的 .git/config（remote、用户设置等），其余全部换成新构建结果。
if [ -f "$TARGET/.git/config" ]; then
  cp "$TARGET/.git/config" "$BUILD/.git/config"
fi

if [ -e "$TARGET" ]; then
  mv "$TARGET" "$BACKUP" || die "无法移动旧目标到备份：$BACKUP"
fi
if ! mv "$BUILD" "$TARGET"; then
  if [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$TARGET" || warn "恢复旧目标失败，备份在：$BACKUP"
  fi
  die "无法把构建结果移动到目标：$TARGET"
fi
if [ -e "$BACKUP" ]; then
  rm -rf "$BACKUP" || warn "旧目标备份删除失败：$BACKUP"
fi

echo
log "=== 构建完成 ==="
log "目标: $TARGET"
log "分支:"
git -C "$TARGET" branch -a | cat
log "日期标签（git tag 按名字排序即时间顺序）:"
git -C "$TARGET" tag -l | sort | sed 's/^/  /'
