#!/usr/bin/env bash
# <region>/build.sh — 宪制历史构建脚本（Bash 版，离线）
# 用法: bash <region>/build.sh <目标Git仓库路径>
#
# 本脚本不访问网络：法律文本全部随本仓库保存在 <region>/texts/ 下，
# 由 <region>/texts/manifest.tsv 描述分支、日期、时区与提交信息。
# 文本的更新由 tools/update-sources.sh 负责（维护者操作，日常构建不涉及）。
#
# 每次提交会打一个以真实日期命名的轻量标签（主分支为裸日期，历史分支为
# "<日期>-<分支名>"），以便在 git log --decorate 与 GitHub 上直接看出日期——
# Git 本身无法渲染 1970-01-01 之前的提交日期。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="$(basename "$SCRIPT_DIR")"
TEXTS_DIR="$SCRIPT_DIR/texts"
MANIFEST="$TEXTS_DIR/manifest.tsv"
REPO_PATH="${1:-.}"

if [ ! -f "$MANIFEST" ]; then
  echo "[!] 找不到文本清单：$MANIFEST" >&2; exit 1
fi

if [ ! -d "$REPO_PATH" ]; then
  mkdir -p "$REPO_PATH"; cd "$REPO_PATH"; git init -q
elif [ ! -d "$REPO_PATH/.git" ]; then
  cd "$REPO_PATH"; git init -q
fi

TARGET_REPO="$(cd "$REPO_PATH" && pwd)"; cd "$TARGET_REPO"

GIT_NAME="$(git config user.name || true)"; GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log(){ echo "[*] $*"; }; ok(){ echo "  -> $*"; }; warn(){ echo "[!] $*" >&2; }

# "YYYY-MM-DD" + 时区偏移小时 -> 该日 00:00 的 epoch。
# 必须显式算 epoch：写 "YYYY-MM-DD 00:00:00" 会被 git 按本机时区解析（结果随构建机 TZ
# 变化）；而 1970 年前的日期又无法用日期串表达（git 只接受非负 epoch）。
epoch_at() {
  local d="$1" off="${2:-8}"
  echo $(( $(date -u -d "$d 00:00:00" +%s) - off * 3600 ))
}
tz_hours() { case "$1" in +0000) echo 0 ;; *) echo 8 ;; esac; }

# 标签名：让 1970 年前后的提交在 git log / GitHub 上都能看出真实日期。
# Git 无法渲染 1970-01-01 之前的提交日期（见 README「关于日期显示」），因此给每次
# 提交打一个以日期命名的轻量标签：`git log --decorate` 会在提交旁显示
#   abc1234 (1947-12-25) 1947年12月25日施行《中华民国宪法》
# `git tag` 按名字排序即等于按时间排序，`git describe` 也能用了。
#   主分支用裸日期（最常见、好记）；历史分支加分支名后缀以免与主分支或彼此重名。
tag_for() {  # $1=分支 $2=日期
  if [ "$1" = "main" ]; then printf '%s' "$2"; else printf '%s-%s' "$2" "$1"; fi
}

# 1970 年前的提交：git 无法解析负 epoch，只能手工写 commit 对象再更新 ref。
# 这类提交的对象对 `git fsck` 会报 badDate，属 Git 固有限制。
mk_raw_commit() {  # $1=epoch $2=tz $3=msg $4=parent("-" 为根提交)  -> sha
  local ts="$1" z="$2" msg="$3" parent="$4" tree content
  tree="$(git write-tree)"
  if [ "$parent" = "-" ]; then
    content="tree $tree\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  else
    content="tree $tree\nparent $parent\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  fi
  printf '%b' "$content" | git hash-object -t commit -w --stdin --literally
}

# 1970 年及以后：直接用 git commit（索引/工作区/HHEAD 一致，不会污染主分支索引）
mk_dated_commit() {  # $1=epoch $2=tz $3=msg  -> sha
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" \
  GIT_AUTHOR_DATE="@$1 $2" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" \
  GIT_COMMITTER_DATE="@$1 $2" \
    git commit -q --no-verify -m "$3"
  git rev-parse HEAD
}

clean_repo() {
  log "清理目标仓库..."
  local root; root="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
  if [ -n "$root" ]; then
    git checkout main 2>/dev/null || true
    git reset --hard "$root" 2>/dev/null || true
    git rm -r . --quiet 2>/dev/null || true
  fi
  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true
  git add .
  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do
    [ "$b" = "main" ] && continue
    [ -z "$b" ] && continue
    git branch -D "$b" 2>/dev/null && ok "已删除分支: $b" || true
  done
  # 标签是独立于分支的 ref，重建前要一并清掉，否则日期标签会重名
  local t
  for t in $(git tag -l 2>/dev/null); do git update-ref -d "refs/tags/$t"; done
  git symbolic-ref HEAD refs/heads/main
}

build_from_manifest() {
  local first_date first_tz first_epoch
  first_date="$(awk -F'\t' '!/^#/ && NF {print $4; exit}' "$MANIFEST")"
  first_tz="$(awk -F'\t' '!/^#/ && NF {print $5; exit}' "$MANIFEST")"
  if [ -z "$first_date" ]; then warn "清单为空：$MANIFEST"; exit 1; fi
  first_epoch="$(epoch_at "$first_date" "$(tz_hours "$first_tz")")"

  clean_repo
  local init
  if [ "$first_epoch" -ge 0 ]; then
    init="$(mk_dated_commit "$first_epoch" "$first_tz" "Initial commit")"
  else
    init="$(mk_raw_commit "$first_epoch" "$first_tz" "Initial commit" "-")"
    git update-ref refs/heads/main "$init"
  fi
  INIT="$init"
  ok "根提交 $INIT（$first_date $first_tz）"

  local branch="" seq=""
  local g_branch="" g_seq="" g_date="" g_tz="" g_msg="" g_epoch=""
  local prev="" prev_branch="" prev_seq=""
  local -a g_files=() g_outs=()

  commit_group() {
    [ ${#g_files[@]} -eq 0 ] && return 0
    local parent="$INIT" i src dst
    # 与上一个提交同一分支则接续；不同分支则从初始提交重新开枝
    if [ "$g_branch" = "$prev_branch" ]; then
      parent="$prev"
    fi
    # 先把目标分支指向父提交并签出，索引与工作区随之就位
    git checkout -q -B "$g_branch" "$parent"
    for i in "${!g_files[@]}"; do
      src="$TEXTS_DIR/${g_files[$i]}"; dst="${g_outs[$i]}"
      if [ ! -f "$src" ]; then warn "缺少文本文件：texts/${g_files[$i]}"; exit 1; fi
      if [ ! -s "$src" ]; then warn "文本文件为空：texts/${g_files[$i]}"; exit 1; fi
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      git add "$dst"
    done
    if [ "$g_epoch" -ge 0 ]; then
      prev="$(mk_dated_commit "$g_epoch" "$g_tz" "$g_msg")"
    else
      local sha; sha="$(mk_raw_commit "$g_epoch" "$g_tz" "$g_msg" "$parent")"
      git update-ref "refs/heads/$g_branch" "$sha"
      prev="$sha"
    fi
    prev_branch="$g_branch"; prev_seq="$g_seq"
    # 打日期标签，使真实日期在 git log --decorate / GitHub 上可见
    local tag; tag="$(tag_for "$g_branch" "$g_date")"
    if git show-ref --verify --quiet "refs/tags/$tag"; then
      warn "标签重名：$tag（$g_branch #$g_seq $g_date）"; exit 1
    fi
    git update-ref "refs/tags/$tag" "$prev"
    ok "$(printf '%-12s #%-2s %-12s %s  %s' "$g_branch" "$g_seq" "$tag" "$g_date" "${g_msg:0:36}")"
    g_files=(); g_outs=()
  }

  while IFS=$'\t' read -r r_branch r_seq r_file r_date r_tz r_out r_msg; do
    case "$r_branch" in ''|\#*) continue ;; esac
    if [ "$r_branch" != "$branch" ] || [ "$r_seq" != "$seq" ]; then
      commit_group
      branch="$r_branch"; seq="$r_seq"
      g_branch="$r_branch"; g_seq="$r_seq"; g_date="$r_date"; g_tz="$r_tz"; g_msg="$r_msg"
      g_epoch="$(epoch_at "$r_date" "$(tz_hours "$r_tz")")"
    fi
    g_files+=("$r_file"); g_outs+=("$r_out")
  done < "$MANIFEST"
  commit_group
}

# 真实日期：直接读 commit 对象里的 epoch，并按其声明的时区显示墙钟时间。
# （不用本机时区渲染，避免 1912—1949 年中国 UTC+9 等历史时区造成的错觉。）
show_dates() {
  log "各分支真实日期（早于 1970 的提交 git log 只会显示 1970-01-01）:"
  local b ts tz off
  while read -r b ts tz; do
    [ -z "${ts:-}" ] && continue
    off="$(tz_hours "$tz")"
    printf '  %-16s %s  %s\n' "$b" "$(date -u -d "@$(( ts + off * 3600 ))" '+%Y-%m-%d %H:%M')" "$tz"
  done < <(
    for b in $(git branch --format='%(refname:short)'); do
      line="$(git cat-file -p "$b" | sed -n 's/^committer .*<[^>]*> \(-\{0,1\}[0-9]*\) \([-+][0-9]*\)$/\1 \2/p')"
      echo "$b $line"
    done
  )
}

main() {
  log "=== legalize-$REGION 宪制历史构建（离线，不访问网络） ==="
  log "目标仓库: $TARGET_REPO"
  log "文本清单: $MANIFEST"
  echo
  build_from_manifest
  echo
  git checkout -q main 2>/dev/null || true
  log "=== 构建完成 ==="; echo
  log "分支一览:"; git branch -a | cat; echo
  log "日期标签（git tag 按名字排序即时间顺序）:"
  git tag -l | sort | while IFS= read -r tag; do
    printf '  %-26s %s\n' "$tag" "$(git log -1 --format=%s "refs/tags/$tag")"
  done
  echo
  show_dates
}

cd "$TARGET_REPO"; main "$@"
