#!/usr/bin/env bash
# <region>/build.sh — 宪制历史构建脚本（Bash 版，离线）
# 用法: bash <region>/build.sh <目标Git仓库路径>
#
# 本脚本不访问网络：法律文本全部随本仓库保存在 <region>/texts/ 下，
# 由 <region>/texts/manifest.tsv 描述分支、日期、时区与提交信息。
# 文本的更新由 tools/update-sources.sh 负责（维护者操作，日常构建不涉及）。
#
# 提交时间戳的处理：
#   1970-01-01 及以后 —— 写入该日「当地 0 点」这一瞬间，即对象里的偏移取 manifest 声明的
#                        偏移，`git log` 的 %ai 恰好是 <日期> 00:00:00 <偏移>。
#   1970-01-01 之前   —— 统一写入 unix 0（1970-01-01 00:00:00 +0000）。
#     原因是 Git 无法表示更早的日期：负 epoch 写进对象后，git log 渲染为 1970-01-01、
#     %ai/%ad/%at 为空、--since/--before 结果不可靠、git fsck 报 badDate，
#     而 GitHub 与部分客户端会直接显示出错（溢出）的时间。
#     统一为 unix 0 后，Git 与 GitHub 都能正常显示，仓库也不再带 fsck 错误。
#     **真实日期改由日期标签承载**（主分支为裸日期，历史分支为 "<日期>-<分支名>"），
#     例如 `git log --decorate` 显示 (tag: 1947-12-25)、`git tag` 排序即编年表。

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

# "+0800" / "+0830" / "-0330" -> 相对 UTC 的秒数（东正西负）。
# 必须支持任意 ±HHMM：各地区不止 +0800（日本/韩国/朝鲜 +0900，越南 +0700，
# 朝鲜 2015-2018 年间的"平壤时间" +0830），写死 +8 会让这些地区的时间戳整体偏掉。
tz_seconds() {  # $1=时区串
  local s="$1" sign=1 body="$1"
  case "$s" in -*) sign=-1; body="${s#-}" ;; +*) body="${s#+}" ;; esac
  printf '%s' $(( sign * (10#${body:0:2} * 3600 + 10#${body:2:2} * 60) ))
}

# "<日期> <时区>" -> "<存入的 epoch> <存入的时区>"
# 存入的值是该日「当地 0 点」这一瞬间，即提交对象的 %ai 恰好是 <日期> 00:00:00 <时区>。
# 1970 年前的日期统一收敛到 unix 0。之所以显式算 epoch 而不写 "YYYY-MM-DD 00:00:00"，
# 是因为后者会被 git 按构建机的本地时区解析，结果随 TZ 变化。
commit_stamp() {  # $1=日期 $2=声明时区
  local d="$1" tz="$2" e
  e=$(( $(date -u -d "$d 00:00:00" +%s) - $(tz_seconds "$tz") ))
  if [ "$e" -lt 0 ]; then
    printf '0 +0000'
  else
    printf '%s %s' "$e" "$tz"
  fi
}

# 标签名：让 1970 年前的提交也能一眼看出真实日期。
#   主分支     -> <日期>              例 1947-12-25
#   历史分支   -> <日期>-<分支名>     例 1917-02-14-英皇制诰
# 按构造即不重名：分支名唯一，主分支与历史分支即使同一天也不会撞。
tag_for() {  # $1=分支 $2=日期
  if [ "$1" = "main" ]; then printf '%s' "$2"; else printf '%s-%s' "$2" "$1"; fi
}

mk_commit() {  # $1=ref $2="<epoch> <tz>" $3=msg  -> 新提交的 sha
  local stamp="$2" msg="$3"
  # git commit 会把 HEAD（指向 $1 的符号引用）一并前移，索引/工作区自然一致
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="@$stamp" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="@$stamp" \
    git commit -q --no-verify -m "$msg"
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
  local first_date first_tz
  first_date="$(awk -F'\t' '!/^#/ && NF {print $4; exit}' "$MANIFEST")"
  first_tz="$(awk -F'\t' '!/^#/ && NF {print $5; exit}' "$MANIFEST")"
  if [ -z "$first_date" ]; then warn "清单为空：$MANIFEST"; exit 1; fi

  clean_repo
  local first_stamp; first_stamp="$(commit_stamp "$first_date" "$first_tz")"
  mk_commit "main" "$first_stamp" "Initial commit" > /dev/null
  INIT="$(git rev-parse HEAD)"
  ok "根提交 $INIT（$first_date -> 时间戳 $first_stamp）"

  local branch="" seq=""
  local g_branch="" g_seq="" g_date="" g_tz="" g_msg="" g_stamp=""
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
    prev="$(mk_commit "$g_branch" "$g_stamp" "$g_msg")"

    # 打日期标签，使真实日期在 git log --decorate / GitHub 上可见。
    # 用 git update-ref 而非 git tag：后者会解析目标提交的日期来写 reflog，
    # 对 1970 年前的时间戳会报 "Timestamp too large for this system" 而失败。
    local tag; tag="$(tag_for "$g_branch" "$g_date")"
    if git show-ref --verify --quiet "refs/tags/$tag"; then
      warn "标签重名：$tag（$g_branch #$g_seq $g_date）"; exit 1
    fi
    git update-ref "refs/tags/$tag" "$prev"

    prev_branch="$g_branch"; prev_seq="$g_seq"
    ok "$(printf '%-12s #%-2s %-26s %-24s %s' "$g_branch" "$g_seq" "$tag" "$g_stamp" "${g_msg:0:32}")"
    g_files=(); g_outs=()
  }

  while IFS=$'\t' read -r r_branch r_seq r_file r_date r_tz r_out r_msg; do
    case "$r_branch" in ''|\#*) continue ;; esac
    if [ "$r_branch" != "$branch" ] || [ "$r_seq" != "$seq" ]; then
      commit_group
      branch="$r_branch"; seq="$r_seq"
      g_branch="$r_branch"; g_seq="$r_seq"; g_date="$r_date"; g_tz="$r_tz"; g_msg="$r_msg"
      g_stamp="$(commit_stamp "$r_date" "$r_tz")"
    fi
    g_files+=("$r_file"); g_outs+=("$r_out")
  done < "$MANIFEST"
  commit_group
}

# 真实日期以标签为准；1970 前的提交在 Git 里存为 unix 0。
# 用 bash 的 ${var:0:N} 截断（按字符），不用 cut -c（按字节，会把中文截成乱码）。
show_dates() {
  log "各提交的真实日期（以日期标签为准）："
  local tag stamp subj when
  for tag in $(git tag -l | sort); do
    stamp="$(git cat-file -p "refs/tags/$tag" | sed -n 's/^committer .*<[^>]*> \([0-9]*\) \([-+][0-9]*\)$/\1 \2/p')"
    subj="$(git log -1 --format='%s' "refs/tags/$tag")"
    if [ "${stamp%% *}" = "0" ]; then
      printf '  %-28s %-16s  %s\n' "$tag" "unix 0" "${subj:0:44}"
    else
      when="$(git log -1 --format='%ad' --date=format:'%Y-%m-%d %H:%M' "refs/tags/$tag")"
      printf '  %-28s %-16s  %s\n' "$tag" "$when" "${subj:0:44}"
    fi
  done
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
  while IFS= read -r tag; do
    printf '  %-28s %s\n' "$tag" "$(git log -1 --format='%s' "refs/tags/$tag")"
  done < <(git tag -l | sort)
  echo
  show_dates
}

cd "$TARGET_REPO"; main "$@"
