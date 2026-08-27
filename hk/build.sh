#!/usr/bin/env bash
# meta/build.sh — 香港宪制历史构建脚本（Bash 版）
# 用法: bash hk/build.sh <目标Git仓库路径>
# 在指定 git 仓库中构建香港宪制文件历史（主分支 + 历史宪制分支）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_PATH="${1:-.}"

if [ ! -d "$REPO_PATH" ]; then
  mkdir -p "$REPO_PATH"
  cd "$REPO_PATH"
  git init
elif [ ! -d "$REPO_PATH/.git" ]; then
  cd "$REPO_PATH"
  git init
fi

TARGET_REPO="$(cd "$REPO_PATH" && pwd)"
cd "$TARGET_REPO"

TMPDIR="$(mktemp -d /tmp/legalize-hk-build.XXXXXX)"
trap "rm -rf '$TMPDIR'" EXIT

GIT_NAME="$(git config user.name || true)"
GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log()  { echo "[*] $*"; }
ok()   { echo "  -> $*"; }
warn() { echo "[!] $*" >&2; }

# 维基文库抓取：持久缓存 + 限流退避重试（避免 429）
WIKICACHE="${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}"
mkdir -p "$WIKICACHE"

wiki_fetch() {  # $1=host(en|zh) $2=title
  local host="$1" title="$2"
  local key
  key="$(printf '%s|%s' "$host" "$title" | md5sum | cut -d' ' -f1)"
  local cache="$WIKICACHE/$key"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi

  local url code rc attempt wait
  if [ "$host" = "en" ]; then
    url="https://en.wikisource.org/w/index.php?action=raw"
  else
    url="https://zh.wikisource.org/w/index.php?action=raw"
  fi

  for attempt in 1 2 3 4 5 6; do
    rm -f "$TMPDIR/fetch.$$"
    code="$(curl -sS --max-time 30 -o "$TMPDIR/fetch.$$" -w '%{http_code}' --get --data-urlencode "title=$title" "$url" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
      mv "$TMPDIR/fetch.$$" "$cache"
      cat "$cache"
      return 0
    fi
    wait=$(( attempt * attempt * 3 ))
    [ "$wait" -gt 60 ] && wait=60
    rm -f "$TMPDIR/fetch.$$"
    warn "  [fetch] $host:$title http=$code rc=$rc 重试($attempt/6) ${wait}s"
    sleep "$wait"
  done
  warn "  [fetch] 失败: $host:$title"
  return 1
}

wiki_raw() { wiki_fetch en "$1"; }

wiki_to_markdown() {
  sed -E \
    -e 's/<noinclude>.*<\/noinclude>//g' \
    -e 's/\{\{[^{}]*\}\}//g' \
    -e "s/'''([^']*)'''/**\1**/g" \
    -e "s/''([^']*)''/*\1*/g" \
    -e 's/^====[[:space:]]*(.*)[[:space:]]*====$/#### \1/g' \
    -e 's/^===[[:space:]]*(.*)[[:space:]]*===$/### \1/g' \
    -e 's/^==[[:space:]]*(.*)[[:space:]]*==$/## \1/g' \
    -e 's/\[\[[^]|]*\|([^]]*)\]\]/\1/g' \
    -e 's/\[\[([^]]*)\]\]/\1/g' \
    -e 's/&nbsp;/ /g'
}

build_toc() {
  grep '^## ' "$1" | sed 's/^## //' | while IFS= read -r line; do
    anchor="$(printf '%s' "$line" | sed 's/　//g; s/ //g')"
    printf -- '- [%s](#%s)\n' "$line" "$anchor"
  done || true
}

clean_repo() {
  log "清理目标仓库..."

  local root
  root="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"

  if [ -n "$root" ]; then
    git checkout main 2>/dev/null || true
    git reset --hard "$root" 2>/dev/null || true
    git rm -r . --quiet 2>/dev/null || true
  fi

  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true
  git add .

  if [ -n "$root" ]; then
    GIT_AUTHOR_DATE="1990-04-04 08:00:00" GIT_COMMITTER_DATE="1990-04-04 08:00:00" \
      git commit --amend --no-edit 2>/dev/null || true
  else
    GIT_AUTHOR_DATE="1990-04-04 08:00:00" GIT_COMMITTER_DATE="1990-04-04 08:00:00" \
      git commit -m "Initial commit" 2>/dev/null || true
  fi
  git branch -M main
  log "根提交: $(git rev-parse HEAD)"

  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do
    [ "$b" = "main" ] && continue
    [ -z "$b" ] && continue
    git branch -D "$b" 2>/dev/null && ok "已删除分支: $b" || true
  done
}

make_historical_commit() {
  local branch="$1" date_ts="$2" tz="$3" msg="$4" file_path="$5" src_file="$6" parent="${7:-}"

  if [ -z "$parent" ]; then
    parent="$(git rev-list --max-parents=0 HEAD | head -1)"
  fi

  local wt="$TMPDIR/wt-$branch"
  rm -rf "$wt"
  git worktree prune 2>/dev/null || true
  git worktree add --detach "$wt" "$parent" 2>/dev/null

  (
    cd "$wt"
    mkdir -p "$(dirname "$file_path")"
    cp "$src_file" "$file_path"
    git add "$file_path"
    tree="$(git write-tree)"
    commit_content="$(printf "tree %s\nparent %s\nauthor %s <%s> %s %s\ncommitter %s <%s> %s %s\n\n%s\n" \
      "$tree" "$parent" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$msg")"
    commit_hash="$(printf '%s' "$commit_content" | git hash-object -t commit -w --stdin --literally)"
    git update-ref "refs/heads/$branch" "$commit_hash"
  )

  git worktree remove "$wt" -f 2>/dev/null || true
  ok "分支 $branch 创建完成"
}

write_basic_law() {
  local target="$1"; shift
  local notes=("$@")
  local body="$TMPDIR/basic-law-body.md"
  local annex1="$TMPDIR/annex1.md"
  local annex2="$TMPDIR/annex2.md"
  local annex3="$TMPDIR/annex3.md"

  wiki_raw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region" | wiki_to_markdown > "$body"
  wiki_raw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_I_(2021)" | wiki_to_markdown > "$annex1"
  wiki_raw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_II_(2021)" | wiki_to_markdown > "$annex2"
  wiki_raw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_III" | wiki_to_markdown > "$annex3"

  {
    echo "# 中华人民共和国香港特别行政区基本法"
    echo
    for note in "${notes[@]}"; do
      echo "> $note"
    done
    echo
    build_toc "$body"
    echo
    cat "$body"
    echo
    echo "---"
    echo
    cat "$annex1"
    echo
    echo "---"
    echo
    cat "$annex2"
    echo
    echo "---"
    echo
    cat "$annex3"
    echo
    echo "---"
    echo
    echo "资料来源："
    echo
    echo "- 香港基本法官方网站：https://www.basiclaw.gov.hk/"
    echo "- 维基文库：https://en.wikisource.org/wiki/Basic_Law_of_the_Hong_Kong_Special_Administrative_Region"
  } > "$target"
}

build_main_branch() {
  log "构建主分支: 香港基本法..."

  mkdir -p "宪制"
  local file="宪制/中华人民共和国香港特别行政区基本法.md"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行"
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="1990-04-04 09:00:00" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="1990-04-04 09:00:00" \
    git commit -m "1990年4月4日第七届全国人民代表大会第三次会议通过《中华人民共和国香港特别行政区基本法》"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行" \
    "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正"
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="2010-08-28 09:00:00" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="2010-08-28 09:00:00" \
    git commit -m "2010年8月28日全国人大常委会批准或备案香港基本法附件一、附件二修正"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行" \
    "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正" \
    "2021年3月30日第十三届全国人大常委会第二十七次会议修订附件一、附件二"
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="2021-03-30 09:00:00" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="2021-03-30 09:00:00" \
    git commit -m "2021年3月30日全国人大常委会修订香港基本法附件一、附件二"

  ok "主分支完成: $(git rev-parse HEAD)"
}

build_historical_branches() {
  log "构建殖民地时期宪制分支..."

  local letters="$TMPDIR/letters.md"
  {
    echo "# Hong Kong Letters Patent 1917"
    echo
    echo "> 1917年2月14日乔治五世颁布；1997年7月1日香港回归后失效。"
    echo
    wiki_raw "Hong_Kong_Letters_Patent_1917" | wiki_to_markdown
    echo
    echo "资料来源：https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917"
  } > "$letters"
  make_historical_commit "英皇制诰" "-1668729600" "+0000" \
    "1917年2月14日颁布《Hong Kong Letters Patent》" \
    "宪制/Hong Kong Letters Patent 1917.md" "$letters"

  local instructions="$TMPDIR/instructions.md"
  {
    echo "# Hong Kong Royal Instructions 1917"
    echo
    echo "> 1917年2月14日乔治五世颁布；1997年7月1日香港回归后失效。"
    echo
    wiki_raw "Hong_Kong_Royal_Instructions_1917" | wiki_to_markdown
    echo
    echo "资料来源：https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917"
  } > "$instructions"
  make_historical_commit "皇室训令" "-1668729600" "+0000" \
    "1917年2月14日颁布《Hong Kong Royal Instructions》" \
    "宪制/Hong Kong Royal Instructions 1917.md" "$instructions"

  ok "历史分支创建完成"
}

main() {
  log "=== legalize-hk 宪制历史构建 ==="
  log "目标仓库: $TARGET_REPO"
  echo

  clean_repo
  echo

  build_main_branch
  echo

  build_historical_branches
  echo

  git checkout main 2>/dev/null || true
  log "=== 构建完成 ==="
  echo
  log "分支一览:"
  git branch -a | cat
  echo
  log "主分支历史:"
  git log --format="%ai %s" --reverse main | cat
}

cd "$TARGET_REPO"
main "$@"
