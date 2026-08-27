#!/usr/bin/env bash
# tw/build.sh — 台湾宪制历史构建脚本（Bash 版）
# 用法: bash tw/build.sh <目标Git仓库路径>
# 在指定 git 仓库中构建台湾宪制文件历史（主分支 + 历史宪法分支）

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

TMPDIR="$(mktemp -d /tmp/legalize-tw-build.XXXXXX)"
trap "rm -rf '$TMPDIR'" EXIT

GIT_NAME="$(git config user.name || true)"
GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log()  { echo "[*] $*"; }
ok()   { echo "  -> $*"; }
warn() { echo "[!] $*"; }

zh_wiki_raw() {
  curl -fsSL --max-time 30 --get --data-urlencode "title=$1" "https://zh.wikisource.org/w/index.php?action=raw"
}

cat > "$TMPDIR/wiki_to_md.py" <<'PY'
import sys, re
text = sys.stdin.read()
while '{{' in text:
    new = re.sub(r'\{\{([^{}]*)\}\}', '', text, flags=re.S)
    if new == text:
        break
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
    if re.match(r'^\[\[(Category|category|分類|分[類类])', s, re.I):
        continue
    if s.startswith('|') and '=' in s:
        continue
    keep.append(ln)
text = '\n'.join(keep)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY

wiki_to_markdown() {
  python3 "$TMPDIR/wiki_to_md.py"
}

build_toc() {
  grep '^## ' "$1" | sed 's/^## //' | while IFS= read -r line; do
    anchor="$(printf '%s' "$line" | sed 's/　//g; s/ //g')"
    printf -- '- [%s](#%s)\n' "$line" "$anchor"
  done || true
}

# 手动构造 commit 对象：GIT 的 GIT_AUTHOR_DATE 无法解析早于 1970 的日期，
# 此函数直接写入树/父/作者/提交者（支持负 epoch），并更新 ref。
mk_commit() {  # $1=ref, $2=epoch, $3=tz, $4=msg, $5=parent(可选; "-" 表示无父)
  local ref="$1" ts="$2" z="$3" msg="$4"
  local parent="${5:-__auto__}"
  local tree content hash
  tree="$(git write-tree)"
  if [ "$parent" = "__auto__" ]; then
    parent="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  fi
  if [ -n "$parent" ] && [ "$parent" != "-" ]; then
    content="tree $tree\nparent $parent\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  else
    content="tree $tree\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  fi

  hash="$(printf '%b' "$content" | git hash-object -t commit -w --stdin --literally)"
  git update-ref "refs/heads/$ref" "$hash"
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

  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do
    [ "$b" = "main" ] && continue
    [ -z "$b" ] && continue
    git branch -D "$b" 2>/dev/null || true
  done

  mk_commit "main" "-694911600" "+0800" "Initial commit" "-"
  git branch -M main
  log "根提交: $(git rev-parse HEAD)"
}

make_historical_commit() {
  local branch="$1" date_ts="$2" tz="$3" msg="$4" file_path="$5" content="$6" parent="${7:-}"

  if [ -z "$parent" ]; then
    parent="$(git rev-list --max-parents=0 HEAD | head -1)"
  fi

  local wt="$TMPDIR/wt-$branch"
  rm -rf "$wt"
  git worktree prune 2>/dev/null || true
  git worktree add --detach "$wt" "$parent" 2>/dev/null || true

  (
    cd "$wt"
    mkdir -p "$(dirname "$file_path")"
    printf '%s\n' "$content" > "$file_path"
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

build_main_branch() {
  log "构建主分支: 宪法本文 + 增修条文..."

  mkdir -p 宪法
  local body="$TMPDIR/宪法本文.md"
  local constitution_file="宪法/中华民国宪法.md"
  local amendment_file="宪法/中华民国宪法增修条文.md"

  zh_wiki_raw "中華民國憲法" | wiki_to_markdown > "$body"
  {
    echo '# 中华民国宪法'
    echo
    echo '> 1946年12月25日制宪国民大会通过'
    echo '> 1947年1月1日国民政府公布'
    echo '> 1947年12月25日施行'
    echo
    build_toc "$body"
    echo
    cat "$body"
  } > "$constitution_file"
  git add "$constitution_file"
  mk_commit "main" "-694911600" "+0800" "1947年12月25日施行《中华民国宪法》"
  ok "本文提交: $(git rev-parse HEAD)"

  # 历次增修条文（每次单独提交，fetch 对应版本子页全文）
  local amend_list=(
    "中華民國憲法增修條文 (民國80年)|1991-05-01|673059600|1991年5月1日制定公布（第1次增修）"
    "中華民國憲法增修條文 (民國81年)|1992-05-28|707014800|1992年5月28日增订公布第11至18条（第2次增修）"
    "中華民國憲法增修條文 (民國83年)|1994-08-01|775702800|1994年8月1日修正公布全文（第3次增修）"
    "中華民國憲法增修條文 (民國86年)|1997-07-21|869446800|1997年7月21日修正公布全文（第4次增修）"
    "中華民國憲法增修條文 (民國88年)|1999-09-15|937357200|1999年9月15日修正公布（第5次增修，后经大法官释字第499号失效）"
    "中華民國憲法增修條文 (民國89年)|2000-04-25|956624400|2000年4月25日修正公布全文（第6次增修）"
    "中華民國憲法增修條文 (民國93年立法94年公布)|2005-06-10|1118365200|2005年6月10日修正公布（第7次增修，现行）"
  )

  local notes="> 1947年12月25日施行《中华民国宪法》本文"
  for item in "${amend_list[@]}"; do
    local title="${item%%|*}"; local rest="${item#*|}"
    local date_str="${rest%%|*}"; local rest2="${rest#*|}"
    local epoch="${rest2%%|*}"; local msg_line="${rest2#*|}"

    log "  提交: $date_str — $msg_line"
    local amend_body="$TMPDIR/amend.md"
    if ! zh_wiki_raw "$title" > "$TMPDIR/amend-raw.md" 2>/dev/null; then
      warn "  fetch 失败，跳过: $title"
      continue
    fi
    wiki_to_markdown < "$TMPDIR/amend-raw.md" > "$amend_body"

    notes="$notes\n> $msg_line"

    {
      echo '# 中华民国宪法增修条文'
      echo
      printf '%b\n' "$notes"
      echo
      build_toc "$amend_body"
      echo
      cat "$amend_body"
    } > "$amendment_file"

    git add "$amendment_file"
    mk_commit "main" "$epoch" "+0800" "$msg_line"
    ok "  提交完成: $(git rev-parse HEAD)"
  done

  ok "主分支完成: $(git rev-parse HEAD)"
}

add_pre1947() {  # $1=分支名 $2=维基文库标题 $3=epoch $4=标题 $5=说明
  local branch="$1" title="$2" epoch="$3" display="$4" note="$5"
  local ref_body="$TMPDIR/$branch.md"
  if ! zh_wiki_raw "$title" > "$TMPDIR/$branch-raw.md" 2>/dev/null; then
    warn "  fetch 失败，跳过: $title"
    return
  fi
  wiki_to_markdown < "$TMPDIR/$branch-raw.md" > "$ref_body"
  local ref_file="$TMPDIR/ref-$branch.md"
  {
    printf '# %s\n\n> %s\n\n' "$display" "$note"
    build_toc "$ref_body"
    printf '\n\n'
    cat "$ref_body"
    printf '\n\n---\n\n资料来源：https://zh.wikisource.org/wiki/%s\n' "$title"
  } > "$ref_file"
  make_historical_commit "$branch" "$epoch" "+0800" "$note" "宪法/$branch.md" "$(cat "$ref_file")"
}

build_historical_branches() {
  log "构建历史宪法分支..."

  local body="$TMPDIR/宪法本文.md"

  local content_file="$TMPDIR/1947宪法.md"
  {
    printf '# 中华民国宪法\n\n> 1946年12月25日制宪国民大会通过\n> 1947年1月1日国民政府公布\n> 1947年12月25日施行\n\n'
    build_toc "$body"
    printf '\n\n'
    cat "$body"
  } > "$content_file"

  make_historical_commit "1947宪法" "-726447600" "+0800" \
    "1946年12月25日制宪国民大会通过《中华民国宪法》" \
    "宪法/中华民国宪法.md" "$(cat "$content_file")"

  # 1947 年之前的中华民国制宪沿革（历史分支）
  add_pre1947 "临时约法" "中華民國臨時約法" "-1824332400" "中华民国临时约法" "1912年3月11日南京临时政府公布（《中华民国临时约法》）"
  add_pre1947 "袁记约法" "中華民國約法" "-1756854000" "中华民国约法" "1914年5月1日公布（《中华民国约法》，世称袁记约法）"
  add_pre1947 "曹锟宪法" "曹錕憲法" "-1458860400" "曹锟宪法" "1923年10月10日公布（《中华民国宪法》，世称曹锟宪法）"
  add_pre1947 "训政约法" "中華民國訓政時期約法" "-1219446000" "中华民国训政时期约法" "1931年5月12日国民会议制定（《中华民国训政时期约法》）"
  add_pre1947 "五五宪草" "五五憲草" "-1062198000" "中华民国宪法草案" "1936年5月5日国民政府公布（《中华民国宪法草案》，世称五五宪草，未施行）"
}

main() {
  log "=== legalize-tw 宪制历史构建 ==="
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
