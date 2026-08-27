#!/usr/bin/env bash
# kp/build.sh — 朝鲜宪制历史构建脚本（Bash 版）
# 用法: bash kp/build.sh <目标Git仓库路径>
# 在指定 git 仓库中构建朝鲜宪制文件历史（主分支 = 现行《朝鲜民主主义人民共和国社会主义宪法》；1972 宪法历史分支）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PATH="${1:-.}"

if [ ! -d "$REPO_PATH" ]; then
  mkdir -p "$REPO_PATH"; cd "$REPO_PATH"; git init
elif [ ! -d "$REPO_PATH/.git" ]; then
  cd "$REPO_PATH"; git init
fi

TARGET_REPO="$(cd "$REPO_PATH" && pwd)"; cd "$TARGET_REPO"
TMPDIR="$(mktemp -d /tmp/legalize-kp-build.XXXXXX)"; trap "rm -rf '$TMPDIR'" EXIT

GIT_NAME="$(git config user.name || true)"; GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"; [ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log(){ echo "[*] $*"; }; ok(){ echo "  -> $*"; }; warn(){ echo "[!] $*" >&2; }

# 维基文库抓取：持久缓存 + 限流退避重试（避免 429）
WIKICACHE="${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}"; mkdir -p "$WIKICACHE"
wiki_fetch() {
  local host="$1" title="$2"
  local key; key="$(printf '%s|%s' "$host" "$title" | md5sum | cut -d' ' -f1)"
  local cache="$WIKICACHE/$key"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  local url code rc attempt wait
  if [ "$host" = "en" ]; then url="https://en.wikisource.org/w/index.php?action=raw"; else url="https://zh.wikisource.org/w/index.php?action=raw"; fi
  for attempt in 1 2 3 4 5 6; do
    rm -f "$TMPDIR/fetch.$$"
    code="$(curl -sS --max-time 30 -o "$TMPDIR/fetch.$$" -w '%{http_code}' --get --data-urlencode "title=$title" "$url" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then mv "$TMPDIR/fetch.$$" "$cache"; cat "$cache"; return 0; fi
    wait=$(( attempt * attempt * 3 )); [ "$wait" -gt 60 ] && wait=60
    rm -f "$TMPDIR/fetch.$$"; warn "  [fetch] $host:$title http=$code rc=$rc 重试($attempt/6) ${wait}s"; sleep "$wait"
  done
  warn "  [fetch] 失败: $host:$title"; return 1
}

cat > "$TMPDIR/wiki_to_md.py" <<'PY'
import sys, re
text = sys.stdin.read()
while '{{' in text:
    new = re.sub(r'\{\{([^{}]*)\}\}', '', text, flags=re.S)
    if new == text: break
    text = new
text = re.sub(r'(?is)<noinclude>.*?</noinclude>', '', text)
text = re.sub(r'(?is)</?onlyinclude>', '', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r"(?s)'''(.*?)'''", r'**\1**', text)
text = re.sub(r"(?s)''(.*?)''", r'*\1*', text)
text = re.sub(r'(?m)^====\s*(.*?)\s*====$', r'#### \1', text)
text = re.sub(r'(?m)^===\s*(.*?)\s*===$', r'### \1', text)
text = re.sub(r'(?m)^==\s*(.*?)\s*==$', r'## \1', text)
text = re.sub(r'\[\[[^\]|]+\|([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)
text = text.replace('&nbsp;', ' ')
text = re.sub(r'\r\n', '\n', text)
text = re.sub(r'(?m)^[ \t\u3000:;]+', '', text)
keep = []
for ln in text.split('\n'):
    s = ln.strip()
    if re.match(r'^\[\[(Category|category|分類|分[類类])', s, re.I): continue
    if s.startswith('|') and '=' in s: continue
    keep.append(ln)
text = '\n'.join(keep)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY
wiki_to_markdown(){ python3 "$TMPDIR/wiki_to_md.py"; }

build_toc() {
  grep '^## ' "$1" | sed 's/^## //' | while IFS= read -r line; do
    anchor="$(printf '%s' "$line" | sed 's/　//g; s/ //g')"; printf -- '- [%s](#%s)\n' "$line" "$anchor"
  done || true
}

mk_commit() {  # $1=ref $2=epoch $3=tz $4=msg $5=parent(可选; "-"=无父)
  local ref="$1" ts="$2" z="$3" msg="$4"; local parent="${5:-__auto__}"
  local tree content hash; tree="$(git write-tree)"
  if [ "$parent" = "__auto__" ]; then parent="$(git rev-parse --verify HEAD 2>/dev/null || true)"; fi
  if [ -n "$parent" ] && [ "$parent" != "-" ]; then content="tree $tree\nparent $parent\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  else content="tree $tree\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"; fi
  hash="$(printf '%b' "$content" | git hash-object -t commit -w --stdin --literally)"; git update-ref "refs/heads/$ref" "$hash"
}

clean_repo() {
  log "清理目标仓库..."
  local root; root="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
  if [ -n "$root" ]; then git checkout main 2>/dev/null || true; git reset --hard "$root" 2>/dev/null || true; git rm -r . --quiet 2>/dev/null || true; fi
  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true; git add .
  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do [ "$b" = "main" ] && continue; [ -z "$b" ] && continue; git branch -D "$b" 2>/dev/null || true; done
  mk_commit "main" "1694134800" "+0800" "Initial commit" "-"; git branch -M main
  log "根提交: $(git rev-parse HEAD)"
}

make_historical_commit() {
  local branch="$1" date_ts="$2" tz="$3" msg="$4" file_path="$5" content="$6" parent="${7:-}"
  if [ -z "$parent" ]; then parent="$(git rev-list --max-parents=0 HEAD | head -1)"; fi
  local wt="$TMPDIR/wt-$branch"; rm -rf "$wt"; git worktree prune 2>/dev/null || true; git worktree add --detach "$wt" "$parent" 2>/dev/null || true
  (
    cd "$wt"; mkdir -p "$(dirname "$file_path")"; printf '%s\n' "$content" > "$file_path"; git add "$file_path"
    local tree; tree="$(git write-tree)"
    local commit_content; commit_content="$(printf "tree %s\nparent %s\nauthor %s <%s> %s %s\ncommitter %s <%s> %s %s\n\n%s\n" "$tree" "$parent" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$msg")"
    local commit_hash; commit_hash="$(printf '%s' "$commit_content" | git hash-object -t commit -w --stdin --literally)"
    git update-ref "refs/heads/$branch" "$commit_hash"
  )
  git worktree remove "$wt" -f 2>/dev/null || true; ok "分支 $branch 创建完成"
}

# 主分支：现行《朝鲜民主主义人民共和国社会主义宪法》（最新可获全文 2023 年修订）
CURRENT_DISPLAY="朝鲜民主主义人民共和国社会主义宪法"
CURRENT_FILE="宪法/朝鲜民主主义人民共和国社会主义宪法.md"
CURRENT_HOST="zh"
CURRENT_TITLE="朝鲜民主主义人民共和国社会主义宪法 (2023年)"
CURRENT_TS="1694134800"
CURRENT_MSG="现行《朝鲜民主主义人民共和国社会主义宪法》（2023年修订文本）"
CURRENT_NOTES=( "> 1972年12月27日通过《朝鲜民主主义人民共和国社会主义宪法》" "> 经1992、1998、2009、2010、2012、2013、2016、2019、2023年历次修订" )

# 历史宪法分支: BRANCH|HOST|TITLE|TS|DISPLAY|NOTE
HIST=(
  "1972宪法|zh|朝鲜民主主义人民共和国社会主义宪法 (1972年)|94266000|1972年宪法|1972年12月27日通过（《朝鲜民主主义人民共和国社会主义宪法》）"
)

build_main_branch() {
  log "构建主分支: $CURRENT_DISPLAY..."
  mkdir -p 宪法
  local body="$TMPDIR/current.md"
  if ! wiki_fetch "$CURRENT_HOST" "$CURRENT_TITLE" > "$TMPDIR/current-raw.md" 2>/dev/null; then warn "  现行宪法抓取失败: $CURRENT_TITLE"; return 1; fi
  wiki_to_markdown < "$TMPDIR/current-raw.md" > "$body"
  {
    echo "# $CURRENT_DISPLAY"; echo
    for n in "${CURRENT_NOTES[@]}"; do echo "$n"; done
    echo; build_toc "$body"; echo; cat "$body"
    echo; echo "---"; echo "资料来源：https://zh.wikisource.org/wiki/${CURRENT_TITLE}"
  } > "$CURRENT_FILE"
  git add "$CURRENT_FILE"; mk_commit "main" "$CURRENT_TS" "+0800" "$CURRENT_MSG"
  ok "主分支完成: $(git rev-parse HEAD)"
}

build_historical_branches() {
  log "构建历史宪法分支..."
  local item branch host title ts display note rawf bodyf outf r
  for item in "${HIST[@]}"; do
    branch="${item%%|*}"; r="${item#*|}"
    host="${r%%|*}"; r="${r#*|}"; title="${r%%|*}"; r="${r#*|}"; ts="${r%%|*}"; r="${r#*|}"; display="${r%%|*}"; note="${r#*|}"
    rawf="$TMPDIR/$branch-raw.md"; bodyf="$TMPDIR/$branch.md"; outf="$TMPDIR/ref-$branch.md"
    if ! wiki_fetch "$host" "$title" > "$rawf" 2>/dev/null; then warn "  [fetch] $title 失败，跳过"; continue; fi
    wiki_to_markdown < "$rawf" > "$bodyf"
    { printf '# %s\n\n> %s\n\n' "$display" "$note"; build_toc "$bodyf"; printf '\n\n'; cat "$bodyf"; printf '\n\n---\n\n资料来源：https://%s.wikisource.org/wiki/%s\n' "$host" "$title"; } > "$outf"
    make_historical_commit "$branch" "$ts" "+0800" "$note" "宪法/$branch.md" "$(cat "$outf")"
  done
}

main() {
  log "=== legalize-kp 宪制历史构建 ==="; log "目标仓库: $TARGET_REPO"; echo
  clean_repo; echo; build_main_branch; echo; build_historical_branches; echo
  git checkout main 2>/dev/null || true
  log "=== 构建完成 ==="; echo; log "分支一览:"; git branch -a | cat; echo; log "主分支历史:"; git log --format="%ai %s" --reverse main | cat
}

cd "$TARGET_REPO"; main "$@"
